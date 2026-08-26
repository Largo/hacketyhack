import { test, expect } from "@playwright/test";
import { bootApp } from "./helpers.mjs";

// A Shoes window resizes unless the program says otherwise, and a Shoes
// program lays out against the size it is given. So the page hands a resizable
// app the whole viewport and tells it to lay out again, rather than drawing it
// at the size it asked for and stretching the result.
// page.setViewportSize returns before the page's own resize event fires, and
// the app only hears about it on the frame after that -- so wait for the app
// to report the size rather than assuming one settle was enough.
async function resizeTo(page, app, size, expectedWidth) {
  await page.setViewportSize(size);
  await expect
    .poll(async () => {
      await app.settle();
      const [win] = await app.windows();
      return win.width;
    })
    .toBe(expectedWidth);
}

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

    // Still wider than the 790 Hackety Hack declares, so it follows the window.
    await resizeTo(page, app, { width: 900, height: 700 }, 900);

    expect((await app.describe()).drawables.width).toBe(900);
    expect(before).not.toBe(900);
  });

  test("a window smaller than the app scrolls rather than squashing it", async ({ page }) => {
    // Below the size a program was written against, reflowing stops helping --
    // text and controls start overlapping instead. So the app keeps its
    // declared size and the page grows scrollbars to reach the rest of it.
    const app = await bootApp(page);

    // 790 is the width Hackety Hack declares, and its floor.
    await resizeTo(page, app, { width: 500, height: 400 }, 790);

    const [win] = await app.windows();
    expect(win.width, "the app was squashed below its declared width").toBeGreaterThan(500);
    expect(win.height).toBeGreaterThan(400);

    const overflow = await page.evaluate(() => ({
      horizontal: document.body.scrollWidth - document.documentElement.clientWidth,
      vertical: document.body.scrollHeight - document.documentElement.clientHeight,
    }));
    expect(overflow.horizontal, "no way to scroll to the rest of it").toBeGreaterThan(0);
    expect(overflow.vertical).toBeGreaterThan(0);
  });

  test("growing the window back does not leave a stray scrollbar", async ({ page }) => {
    // Sizing the canvas can summon a scrollbar, and a scrollbar changes the
    // viewport the canvas was measured against -- so the fit runs again.
    const app = await bootApp(page);

    await resizeTo(page, app, { width: 500, height: 400 }, 790);
    await resizeTo(page, app, { width: 1000, height: 800 }, 1000);

    const overflow = await page.evaluate(() => ({
      horizontal: document.body.scrollWidth - document.documentElement.clientWidth,
      vertical: document.body.scrollHeight - document.documentElement.clientHeight,
    }));
    expect(overflow.horizontal).toBe(0);
    expect(overflow.vertical).toBe(0);
  });
});

test.describe("persistence", () => {
  test("a program written in the app survives a reload", async ({ page }) => {
    // The wasm filesystem is built fresh on every load, so without this the
    // IDE greeted a returning user with "You have no programs" -- while the
    // preference saying they had been here before did survive.
    const app = await bootApp(page);

    await app.ruby(`
      require "fileutils"
      FileUtils.makedirs(HH::USER)
      File.write(File.join(HH::USER, "Persisted.rb"), "alert 'still here'")
      "ok"
    `);
    await page.evaluate(() => window.__clogsPersist.save());

    await page.reload();
    await page.waitForFunction(() => window.__clogsStatus === "ready", null, { timeout: 120_000 });

    const contents = await page.evaluate(() =>
      window.__clogsVM.eval(`File.read(File.join(HH::USER, "Persisted.rb")) rescue "MISSING"`).toString());
    expect(contents).toBe("alert 'still here'");
  });

  test("the IDE lists a program it saved last time", async ({ page }) => {
    const app = await bootApp(page);
    await app.ruby(`
      require "fileutils"
      FileUtils.makedirs(HH::USER)
      File.write(File.join(HH::USER, "Yesterdays Program.rb"), "para 'hello'")
      "ok"
    `);
    await page.evaluate(() => window.__clogsPersist.save());

    await page.reload();
    await page.waitForFunction(() => window.__clogsStatus === "ready", null, { timeout: 120_000 });
    await page.evaluate(() => { window.clogs.advance(3000); });

    const texts = await page.evaluate(() =>
      window.clogs.find(/[^]/).map((hit) => hit.text).filter(Boolean));
    expect(texts).toContain("Yesterdays Program");
  });

  test("only the home directory is kept, not the whole filesystem", async ({ page }) => {
    // The app, its samples and its lessons are shipped in the bundle and would
    // be several megabytes of localStorage for no reason.
    await bootApp(page);
    await page.evaluate(() => window.__clogsPersist.save());

    const saved = await page.evaluate(() => JSON.parse(window.localStorage.getItem("hh.home") || "null"));
    expect(saved).not.toBeNull();
    for (const path of Object.keys(saved.files)) {
      expect(path.startsWith(".hacketyhack"), `${path} is not in the home directory`).toBe(true);
    }
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
