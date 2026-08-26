import { test, expect } from "@playwright/test";
import { bootApp, bootIDE } from "./helpers.mjs";

// `stack :scroll => true` gives a slot its own scrollbar and scrolls its
// contents under it. Hackety Hack asks for exactly that in the two places that
// matter -- the lesson pane and the editor's code area -- and until it existed
// everything past the bottom edge was simply unreachable.

const SCROLLER = `
  Shoes.app :width => 300, :height => 200 do
    stack :width => 1.0, :height => 200, :scroll => true do
      40.times { |i| para "line " + i.to_s }
    end
  end
`;

// The innermost scrolling slot that actually has somewhere to scroll.
const state = (app) => app.ruby(`
  require "json"
  found = nil
  Clogs::App.instances.last.document_root.each_peer do |peer|
    found = peer if peer.is_a?(Clogs::Slot) && peer.scrolls? && peer.max_scroll > 0
  end
  if found
    JSON.generate({ top: found.scroll_top, max: found.max_scroll,
                    height: found.height, content: found.content_height,
                    bar: found.scrollbar_rect, thumb: found.thumb_rect })
  else
    JSON.generate({ none: true })
  end
`).then(JSON.parse);

test.describe("scrolling slots", () => {
  test("a slot too small for its contents gets a scrollbar", async ({ page }) => {
    const app = await bootApp(page, { warmupMs: 300 });
    await app.ruby(`eval(${JSON.stringify(SCROLLER)}, HH.anonymous_binding); "ok"`);
    await app.advance(200);

    const s = await state(app);
    expect(s.none).toBeUndefined();
    expect(s.content, "the contents should be taller than the slot").toBeGreaterThan(s.height);
    expect(s.max).toBe(s.content - s.height);

    // The bar is inside the slot's own box, at its right edge.
    expect(s.bar).not.toBeNull();
    expect(s.thumb[3], "the thumb should be shorter than the track").toBeLessThan(s.bar[3]);
    expect(s.thumb[3]).toBeGreaterThan(0);
  });

  test("the wheel scrolls it, and stops at both ends", async ({ page }) => {
    const app = await bootApp(page, { warmupMs: 300 });
    await app.ruby(`eval(${JSON.stringify(SCROLLER)}, HH.anonymous_binding); "ok"`);
    await app.advance(200);

    const before = await state(app);
    expect(before.top).toBe(0);

    await app.wheel(150, 100, 120, 2);
    const scrolled = await state(app);
    expect(scrolled.top, "the wheel did not scroll it").toBe(120);
    // The thumb moved down with it.
    expect(scrolled.thumb[1]).toBeGreaterThan(before.thumb[1]);

    // Past the end it stops rather than running off.
    await app.wheel(150, 100, 100000, 2);
    expect((await state(app)).top).toBe(before.max);

    // And back to the top, not past it.
    await app.wheel(150, 100, -100000, 2);
    expect((await state(app)).top).toBe(0);
  });

  test("what is scrolled out of sight cannot be clicked", async ({ page }) => {
    // A drawable scrolled above its slot still has a real position -- it is
    // simply above the slot. Without the clip being part of hit testing it
    // would go on catching clicks from wherever that position landed, over
    // whatever is drawn there.
    const app = await bootApp(page, { warmupMs: 300 });
    await app.ruby(`
      $clicked = []
      eval(<<~'RB', HH.anonymous_binding)
        Shoes.app :width => 300, :height => 120 do
          stack :width => 1.0, :height => 120, :scroll => true do
            20.times { |i| para link("row " + i.to_s) { $clicked << i } }
          end
        end
      RB
      "ok"
    `);
    await app.advance(300);

    const rowY = async (i) => Number(await app.ruby(`
      app = Clogs::App.instances.last
      hit = nil
      app.document_root.each_peer do |peer|
        next unless peer.is_a?(Clogs::Para) && peer.abs_y
        text = Array(peer.style(:text_items)).grep(String).join
        hit = peer if text.include?("row ${i}") || (peer.respond_to?(:children) && false)
      end
      (hit ? hit.abs_y : -1).to_s
    `));

    // Scroll a long way, so the early rows are above the slot.
    await app.wheel(150, 60, 400, 2);
    await app.advance(200);

    const y0 = await rowY(0);
    expect(y0, "row 0 should now be above the slot").toBeLessThan(0);

    // Clicking where row 0 now "is" must not reach it.
    await app.ruby(`$clicked.clear; "ok"`);
    await app.click(60, 10, 2);
    await app.advance(200);
    expect(JSON.parse(await app.ruby(`require "json"; JSON.generate($clicked)`)),
      "a row scrolled out of sight still caught a click").not.toContain(0);
  });

  test("the editor's code area scrolls a long program", async ({ page }) => {
    // Short enough that forty lines do not fit -- the app never lays out
    // smaller than the 790x550 it declares, so this is its floor.
    await page.setViewportSize({ width: 900, height: 560 });
    const app = await bootIDE(page);
    const tabs = (await app.find("Image")).filter((i) => i.x < 60 && i.width <= 30).sort((a, b) => a.y - b.y);
    await app.click(tabs[1].centerX, tabs[1].centerY);
    await app.advance(800);

    await app.click(500, 300);
    for (let i = 0; i < 40; i++) {
      await app.type(`line ${i}`);
      await app.key("Enter");
    }
    await app.advance(600);

    const s = await state(app);
    expect(s.none, "nothing in the editor overflowed").toBeUndefined();
    expect(s.max).toBeGreaterThan(0);

    // Typing keeps the caret in view, so it is already scrolled to the end --
    // that is Hackety Hack driving scroll_top itself, through the display side.
    expect(s.top).toBe(s.max);

    await app.wheel(500, 300, -1000);
    expect((await state(app)).top).toBe(0);
  });
});

test.describe("the side tabs", () => {
  test("the icons are big enough to hit", async ({ page }) => {
    // 16 pixels was the size of the artwork, not a sensible target -- and on a
    // dense display it is physically tiny.
    const app = await bootIDE(page);
    const icons = (await app.find("Image"))
      .filter((image) => image.x < 60 && image.width <= 32)
      .sort((a, b) => a.y - b.y);

    expect(icons.length).toBeGreaterThan(5);
    for (const icon of icons) {
      expect(icon.width, "a side tab icon is too small to hit comfortably").toBeGreaterThanOrEqual(24);
      expect(icon.height).toBeGreaterThanOrEqual(24);
    }
    // And spaced out, not touching.
    expect(icons[1].y - icons[0].y).toBeGreaterThanOrEqual(icons[0].height + 8);
  });

  test("each icon still opens its own tab", async ({ page }) => {
    const app = await bootIDE(page);
    const icons = (await app.find("Image"))
      .filter((image) => image.x < 60 && image.width <= 32)
      .sort((a, b) => a.y - b.y);

    const openTab = () => app.ruby(`
      tabs = HH::APP.instance_variable_get(:@__side_tab_class)
      current = tabs && tabs.instance_variable_get(:@current_tab)
      current ? current.class.name.split("::").last : "none"
    `);

    for (const [index, expected] of [[1, "Editor"], [2, "Lessons"], [0, "Home"]]) {
      await app.click(icons[index].centerX, icons[index].centerY);
      await app.advance(700);
      expect(await openTab(), `side tab ${index}`).toBe(expected);
    }
  });
});
