import { test, expect } from "@playwright/test";
import { bootApp } from "./helpers.mjs";

// The same twelve Shoes programs `rake samples` runs against the native
// backends. Eleven open a window; Guessing Game is a bare ask/alert loop with
// no Shoes.app in it at all, which is why the native suite holds it out.
//
// `paints` says whether the sample puts anything on the canvas by itself. Three
// do not, and none of that is new here -- see the test below, which pins the
// two that are actually broken so that fixing them is noticed.
const SAMPLES = [
  { name: "Animated Flowers", paints: false },
  { name: "Arcs", paints: false },
  { name: "Clock", paints: true },
  { name: "Duel", paints: true },
  { name: "Follow", paints: true },
  { name: "Fractal", paints: true },
  { name: "Funnies", paints: true },
  { name: "Pong", paints: true },
  { name: "Scribble", paints: false },
  { name: "Turtle Barbwire", paints: true },
  { name: "Turtle Stars", paints: true },
];

// How many distinct colours are on the canvas. One means nothing was drawn but
// the background.
function countColours(page) {
  return page.evaluate(() => {
    const canvas = document.querySelector("canvas.clogs-window");
    const data = canvas.getContext("2d").getImageData(0, 0, canvas.width, canvas.height).data;
    const seen = new Set();
    for (let i = 0; i < data.length; i += 4) seen.add(`${data[i]},${data[i + 1]},${data[i + 2]}`);
    return seen.size;
  });
}

test.describe("the bundled samples", () => {
  for (const { name, paints } of SAMPLES) {
    test(`${name} runs`, async ({ page }) => {
      // Funnies fetches a comic from a host that has not answered in years;
      // Clogs logs the failure and carries on, which is what it does natively
      // on a machine with no network.
      const app = await bootApp(page, { entry: `/hh/samples/${name}.rb` });

      const windows = await app.windows();
      expect(windows.length).toBeGreaterThanOrEqual(1);
      expect(windows[0].width).toBeGreaterThan(0);

      // Something has to be in the drawable tree: a sample that "runs" but
      // builds nothing is a failure an exit code would miss.
      const root = (await app.describe()).drawables;
      const flat = [];
      (function walk(node) { flat.push(node); (node.children || []).forEach(walk); })(root);
      expect(flat.length, "the sample built no drawables").toBeGreaterThan(1);

      if (paints) {
        expect(await countColours(page), "the canvas is a single flat colour").toBeGreaterThan(1);
      }
    });
  }

  test("Guessing Game runs its dialogs with no window at all", async ({ page }) => {
    // Nobody answers this one on the native backends, which is the whole
    // reason it is the twelfth. In a browser the dialogs are the page's, so a
    // test can simply answer them.
    let answered = 0;
    page.on("dialog", (dialog) => {
      answered += 1;
      dialog.accept("50");
    });

    const app = await bootApp(page, { entry: "/hh/samples/Guessing Game.rb" });
    expect(answered).toBeGreaterThan(0);
    expect(await app.windows()).toHaveLength(0);
  });
});

test.describe("samples that draw nothing", () => {
  test("Scribble is blank until something is scribbled on it", async ({ page }) => {
    const app = await bootApp(page, { entry: "/hh/samples/Scribble.rb" });
    expect(await countColours(page)).toBe(1);

    // Scribble does not draw from the motion event: its `animate` block reads
    // `self.mouse` and draws a segment if the button is down. So the drag has
    // to span frames, with the button still held while they happen.
    await app.drag([[60, 60], [100, 80], [140, 110], [180, 140]], { stepMs: 100 });

    expect(await countColours(page), "dragging drew nothing").toBeGreaterThan(1);
  });

  test("Arcs and Animated Flowers still paint only their background", async ({ page }) => {
    // Neither draws anything on any Clogs backend: their shapes are laid out
    // 0x0 (Arcs) or reach the painter with no fill and no stroke (Animated
    // Flowers), identically under libui. This pins that so a fix is noticed --
    // if this test starts failing, the sample works and `paints` above should
    // change to true.
    for (const name of ["Arcs", "Animated Flowers"]) {
      const app = await bootApp(page, { entry: `/hh/samples/${name}.rb` });
      expect(await countColours(page), `${name} now draws something`).toBe(1);
      void app;
    }
  });
});

test.describe("animation", () => {
  test("an animation runs on the frame clock, not the wall clock", async ({ page }) => {
    // Pong animates by moving drawables, so it keeps repainting.
    const app = await bootApp(page, { entry: "/hh/samples/Pong.rb" });

    const before = await page.evaluate(() => window.clogs.framesPainted());
    // No amount of real time moves it, because the clock belongs to the test.
    await page.waitForTimeout(400);
    expect(await page.evaluate(() => window.clogs.framesPainted())).toBe(before);

    // A second of the app's own time is a second of animation, on any machine.
    await app.advance(1000);
    expect(await page.evaluate(() => window.clogs.framesPainted())).toBeGreaterThan(before);
  });

  test("`clear` inside `animate` stops the animation after one frame", async ({ page }) => {
    // A real Clogs bug, and not one this backend introduced: `animate` is a
    // drawable in the document like any other, so a block that redraws by
    // calling `clear` destroys its own subscription. Clock, whose whole
    // program is `animate { clear { ... } }`, therefore draws one frame and
    // freezes -- identically under libui, where the subscription is likewise
    // gone from the tree a few seconds in.
    //
    // When this is fixed, this test fails and Clock's clock starts ticking.
    const app = await bootApp(page, { entry: "/hh/samples/Clock.rb" });
    await app.advance(3000);

    const subscriptions = await app.ruby(`
      count = 0
      Clogs::App.instances.first.document_root.each_peer do |peer|
        count += 1 if peer.is_a?(Clogs::SubscriptionItem)
      end
      count.to_s
    `);
    expect(Number(subscriptions), "animate now survives its own clear -- this bug is fixed").toBe(0);
  });

  test("a green thread keeps running across frames", async ({ page }) => {
    // Turtle runs the user's drawing in a Thread, blocking on a Queue between
    // steps. wasm has neither, so Clogs gives it a Fiber scheduled between
    // frames; if that regressed, the sample would deadlock rather than draw.
    const app = await bootApp(page, { entry: "/hh/samples/Turtle Stars.rb" });
    await app.advance(1000);

    expect(Number(await app.ruby("Clogs::Wasm::GreenThreads.threads.size.to_s"))).toBe(1);
    expect(await app.ruby("Clogs::Wasm::GreenThreads.threads.first.alive?.to_s")).toBe("true");

    const drawn = await app.ruby(`
      count = 0
      Clogs::App.instances.first.document_root.each_peer { count += 1 }
      count.to_s
    `);
    expect(Number(drawn)).toBeGreaterThan(10);
  });
});
