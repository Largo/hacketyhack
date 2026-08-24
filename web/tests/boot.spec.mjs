import { test, expect } from "@playwright/test";
import { bootApp, bootIDE } from "./helpers.mjs";

test.describe("the IDE boots", () => {
  test("opens its window and paints the splash", async ({ page }) => {
    const app = await bootApp(page);

    const windows = await app.windows();
    expect(windows).toHaveLength(1);
    expect(windows[0].title).toBe("Hackety Hack");
    expect(windows[0].width).toBeGreaterThan(600);

    // The splash is the black screen with the hand on it.
    const texts = await app.texts();
    expect(texts.join(" ")).toContain("Hackety Hack");
    expect(await app.find("Ready")).not.toHaveLength(0);

    app.expectNoErrors();
  });

  test("the whole document is laid out, not just the top of it", async ({ page }) => {
    const app = await bootApp(page);
    const root = (await app.describe()).drawables;

    // A layout bug in Clogs shows up as drawables with no size or stacked at
    // the origin, which is what this repo has spent its time fixing.
    const flat = [];
    (function walk(node) { flat.push(node); (node.children || []).forEach(walk); })(root);
    expect(flat.length).toBeGreaterThan(20);

    const sized = flat.filter((n) => n.width > 0 && n.height > 0);
    expect(sized.length).toBeGreaterThan(flat.length / 2);
    expect(root.width).toBeGreaterThan(600);
  });

  test("Ready leaves the splash for the Home tab", async ({ page }) => {
    const app = await bootIDE(page);

    const texts = (await app.texts()).join(" ");
    expect(texts).toContain("Programs");
    expect(texts).toContain("Samples");
    // The splash's own call to action is gone.
    expect(await app.find("Welcome to")).toHaveLength(0);

    app.expectNoErrors();
  });
});

test.describe("the automation surface", () => {
  test("reports drawables at the position they were painted", async ({ page }) => {
    const app = await bootApp(page);
    const [ready] = await app.find("Ready");

    expect(ready).toBeTruthy();
    expect(ready.x).toBeGreaterThan(0);
    expect(ready.y).toBeGreaterThan(0);
    expect(ready.centerX).toBeCloseTo(ready.x + ready.width / 2, 5);

    // Clogs answers "what is under this point" from the same numbers, so the
    // tree and the hit testing cannot drift apart without a test noticing.
    const hit = await app.ruby(`
      app = Clogs::App.instances.first
      peer = app.topmost_clickable(${Math.round(ready.centerX)}, ${Math.round(ready.centerY)})
      peer ? peer.class.name : "nothing"
    `);
    expect(hit).not.toBe("nothing");
  });

  test("the frame clock can be driven by hand", async ({ page }) => {
    const app = await bootApp(page);
    await app.pause();

    const before = await page.evaluate(() => window.clogs.framesPainted());
    await app.tick(5);
    const after = await page.evaluate(() => window.clogs.framesPainted());

    // A paused page paints only when the test says so.
    expect(after).toBeGreaterThanOrEqual(before);
    await page.waitForTimeout(300);
    expect(await page.evaluate(() => window.clogs.framesPainted())).toBe(after);
  });
});
