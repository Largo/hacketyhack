// Driving Hackety Hack from a test.
//
// Clogs paints a Shoes document into a single <canvas>, so the usual Playwright
// vocabulary -- getByRole, getByText, click a selector -- has nothing to grab
// hold of. What the page exposes instead is `window.clogs`: the drawable tree
// with its on-screen geometry, input that is delivered to the app rather than
// to the DOM, and a frame clock a test can turn by hand. This wraps that up so
// a test reads like it is describing what a person does.
import { expect } from "@playwright/test";

export const BASE = process.env.CLOGS_BASE_URL || "http://localhost:4173";

// Lines Clogs and its dependencies print on every healthy run.
const HARMLESS = [
  /No release found in CHANGELOG/,
  /Unexpected non-style keyword\(s\) in Glossb initialize/,
];

// Boots the page and hands back a driver.
//
// The frame clock is taken away from the browser by default. Left running, an
// app moves on real time and a test is racing it -- which is where flaky canvas
// tests come from. Paused, nothing happens between assertions except what the
// test asks for, and `advance(ms)` delivers exactly that much of the app's own
// time. Pass `paused: false` to watch it run instead.
//
// `warmupMs` is how much of the app's own time to run before handing it over.
export async function bootApp(page, {
  entry = null,
  timeout = 120_000,
  paused = true,
  // The IDE opens on a timed splash sequence and needs it run through. A
  // program you name has nothing to wait for but its first frame -- and since
  // animations really do animate, warming up longer than necessary is real
  // work: Follow rebuilds sixty ovals sixty times a second.
  warmupMs = entry ? 600 : 3000,
} = {}) {
  const consoleErrors = [];
  page.on("console", (message) => {
    const text = message.text();
    if (message.type() !== "warning" && message.type() !== "error") return;
    if (HARMLESS.some((pattern) => pattern.test(text))) return;
    consoleErrors.push(text);
  });
  page.on("pageerror", (error) => consoleErrors.push(`pageerror: ${error.message}`));

  const url = entry ? `${BASE}/?entry=${encodeURIComponent(entry)}` : `${BASE}/`;
  await page.goto(url);
  await page.waitForFunction(
    () => window.__clogsStatus === "ready" || window.__clogsStatus === "error",
    null,
    { timeout },
  );

  const status = await page.evaluate(() => window.__clogsStatus);
  if (status === "error") {
    throw new Error(`Ruby failed to boot: ${await page.evaluate(() => window.__clogsError)}`);
  }

  const app = {
    page,
    consoleErrors,

    // The Shoes drawable tree: types, absolute geometry, and the words on it.
    describe: (windowId = null) => page.evaluate((id) => window.clogs.describe(id), windowId),

    // Every drawable whose text or Shoes class matches, each with a centre to
    // aim at. `query` is a string (substring or class name) or a RegExp source.
    find: (query) =>
      page.evaluate(
        ({ q, isRe }) => window.clogs.find(isRe ? new RegExp(q) : q),
        { q: query instanceof RegExp ? query.source : query, isRe: query instanceof RegExp },
      ),

    // All the text on screen, in tree order. The quickest way to see where an
    // app got to.
    texts: async () =>
      (await page.evaluate(() => window.clogs.find(/[^]/).map((hit) => hit.text))).filter(Boolean),

    windows: () => page.evaluate(() => window.clogs.windows()),

    clickText: async (query, options = {}) => {
      const hit = await page.evaluate(
        ({ q, isRe, opts }) => window.clogs.clickText(isRe ? new RegExp(q) : q, opts),
        { q: query instanceof RegExp ? query.source : query, isRe: query instanceof RegExp, opts: options },
      );
      await app.settle();
      return hit;
    },

    click: async (x, y, windowId = 1) => {
      await page.evaluate(([px, py, id]) => window.clogs.click(px, py, id), [x, y, windowId]);
      await app.settle();
    },

    moveMouse: async (x, y, windowId = 1, held = 0) => {
      await page.evaluate(([px, py, id, h]) => window.clogs.moveMouse(px, py, id, h), [x, y, windowId, held]);
      await app.settle();
    },

    // Press, move and release across a list of [x, y] points -- a scribble, a
    // drag handle, a swipe.
    drag: async (points, options = {}) => {
      await page.evaluate(([p, o]) => window.clogs.drag(p, o), [points, options]);
      await app.settle();
    },

    mouseDown: async (x, y, windowId = 1) => {
      await page.evaluate(([px, py, id]) => window.clogs.mouseDown(px, py, id), [x, y, windowId]);
      await app.settle();
    },

    mouseUp: async (x, y, windowId = 1) => {
      await page.evaluate(([px, py, id]) => window.clogs.mouseUp(px, py, id), [x, y, windowId]);
      await app.settle();
    },

    type: async (text, windowId = 1) => {
      await page.evaluate(([t, id]) => window.clogs.type(t, id), [text, windowId]);
      await app.settle();
    },

    key: async (name, windowId = 1, modifiers = 0) => {
      await page.evaluate(([n, id, m]) => window.clogs.key(n, id, m), [name, windowId, modifiers]);
      await app.settle();
    },

    // Turn the frame clock until nothing repaints. An animating app never
    // stops repainting, so this reports rather than throwing -- assert on
    // `settled` only when the app is meant to be at rest.
    settle: (maxTicks = 12) => page.evaluate((n) => window.clogs.settle(n), maxTicks),

    // Run `ms` of the app's own time. Timers, `animate`, `every` and any
    // sleeping green thread all move by exactly this much.
    advance: (ms, stepMs = 16) =>
      page.evaluate(([m, s]) => window.clogs.advance(m, s), [ms, stepMs]),

    // Advance the clock deliberately: `tick(10)` is ten frames' worth of
    // timers and animation, at exactly 16ms each, no matter how fast the
    // machine is.
    tick: (times = 1, advanceMs = 16) =>
      page.evaluate(([n, ms]) => window.clogs.tick(n, ms), [times, advanceMs]),

    // Hand the clock to the test, so nothing moves except when it says so.
    pause: () => page.evaluate(() => void window.clogs.pause()),
    resume: () => page.evaluate(() => void window.clogs.resume()),

    screenshot: (path) => page.locator("canvas.clogs-window").first().screenshot({ path }),

    // Run Ruby inside the app -- the same VM the app is running in, so this
    // can reach any Clogs or Shoes object. Returns whatever it prints as a
    // string, which is usually the fastest way to answer "what does the app
    // think its state is".
    ruby: (source) => page.evaluate((src) => window.__clogsVM.eval(src).toString(), source),

    expectNoErrors: () => {
      expect(consoleErrors, `app reported errors:\n${consoleErrors.join("\n")}`).toEqual([]);
    },
  };

  if (paused) await app.pause();
  // Hackety Hack opens on a timed splash sequence; the first thing almost any
  // test needs is for that to have finished.
  await app.advance(warmupMs);
  await app.settle(5);
  return app;
}

// The app opens on a splash screen with a Ready link; almost every test of the
// IDE proper wants to be past it.
export async function bootIDE(page, options = {}) {
  const app = await bootApp(page, options);
  await app.clickText("Ready");
  // Ready starts the splash fading out; until that finishes its drawables are
  // still in the tree and still on top of the Home tab.
  await app.advance(2000);
  await app.settle();
  return app;
}
