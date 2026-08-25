import { test, expect } from "@playwright/test";
import { bootApp } from "./helpers.mjs";

// A Shoes window resizes unless the program says otherwise, and a Shoes
// program lays out against the size it is given. So the page hands a resizable
// app the whole viewport and tells it to lay out again, rather than drawing it
// at the size it asked for and stretching the result.
test.describe("window sizing", () => {
  test("a resizable app is given the page and lays out to it", async ({ page }) => {
    const app = await bootApp(page);

    const viewport = page.viewportSize();
    const [win] = await app.windows();

    // Not the 790x550 Hackety Hack asks for -- the page it actually got.
    expect(win.width).toBe(viewport.width);
    expect(win.height).toBe(viewport.height);

    // And laid out to it, rather than scaled up from a smaller drawing.
    const root = (await app.describe()).drawables;
    expect(root.width).toBe(viewport.width);
    expect(root.height).toBe(viewport.height);

    // The backing store matches too, so nothing is being resampled.
    const canvas = await page.evaluate(() => {
      const c = document.querySelector("canvas.clogs-window");
      return {
        css: [parseInt(c.style.width, 10), parseInt(c.style.height, 10)],
        store: [c.width, c.height],
        dpr: window.devicePixelRatio,
      };
    });
    expect(canvas.css).toEqual([viewport.width, viewport.height]);
    expect(canvas.store).toEqual([viewport.width * canvas.dpr, viewport.height * canvas.dpr]);
  });

  test("`resizable: false` keeps the size the program asked for", async ({ page }) => {
    // Arcs opens 420x420 and says it does not resize; Follow and Pong do the
    // same. The viewport is bigger, and it should stay 420x420 anyway.
    const app = await bootApp(page, { entry: "/hh/samples/Arcs.rb" });

    const [win] = await app.windows();
    expect(win.width).toBe(420);
    expect(win.height).toBe(420);
    expect(page.viewportSize().width).toBeGreaterThan(420);
  });

  test("resizing the page re-lays-out the app", async ({ page }) => {
    const app = await bootApp(page);
    const before = (await app.describe()).drawables.width;

    await page.setViewportSize({ width: 640, height: 700 });
    await app.settle();

    const [win] = await app.windows();
    expect(win.width).toBe(640);
    expect((await app.describe()).drawables.width).toBe(640);
    expect(before).not.toBe(640);
  });
});

test.describe("subscription bookkeeping", () => {
  test("every live subscription is indexed, so cancelling one never searches", async ({ page }) => {
    // Lacci cancels a subscription by searching its whole table for the id.
    // Every drawable subscribes six times and Hackety Hack rebuilds a tab by
    // destroying all of it, so that search was most of a second on every visit
    // to the Home tab. Clogs keeps an index instead; if it ever stops being
    // maintained, these two numbers drift apart and the search comes back.
    const app = await bootApp(page);
    await app.clickText("Ready");
    await app.advance(2000);

    const counts = async () => JSON.parse(await app.ruby(`
      require "json"
      table = Shoes::DisplayService.class_variable_get(:@@display_event_handlers)
      live = table.values.sum { |by_target| by_target.values.sum(&:size) }
      empty = table.values.sum { |by_target| by_target.count { |_t, handlers| handlers.empty? } }
      JSON.generate({ live: live, indexed: Clogs.subscription_index.size, empty_buckets: empty })
    `));

    const before = await counts();
    expect(before.indexed).toBe(before.live);
    expect(before.empty_buckets, "emptied buckets are left behind").toBe(0);

    // Rebuild a tab several times: the index must track, not accumulate.
    for (let i = 0; i < 3; i++) {
      await app.ruby(`HH::APP.opentab(:Home); "ok"`);
      await app.advance(300);
    }

    const after = await counts();
    expect(after.indexed).toBe(after.live);
    expect(after.empty_buckets).toBe(0);
    expect(after.live).toBeLessThan(before.live * 2);
  });
});
