import { test, expect } from "@playwright/test";
import { bootApp } from "./helpers.mjs";

// The same twelve Shoes programs `rake samples` runs against the native
// backends. Eleven open a window; Guessing Game is a bare ask/alert loop with
// no Shoes.app in it at all, which is why the native suite holds it out.
//
// `paints` says whether the sample puts anything on the canvas by itself. Only
// Scribble does not, and it is right not to: it draws where the mouse is
// dragged and there is nothing else to it.
const SAMPLES = [
  // Animated Flowers fades its circles in from fully transparent, a step every
  // tenth frame, so it needs a moment before there is anything to see. The
  // rest draw on their first frame, and running an animation for longer than
  // the test needs is real work -- Follow rebuilds sixty ovals sixty times a
  // second.
  { name: "Animated Flowers", paints: true, warmupMs: 600 },
  { name: "Arcs", paints: true },
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
  for (const { name, paints, warmupMs = 200 } of SAMPLES) {
    test(`${name} runs`, async ({ page }) => {
      // Funnies fetches a comic from a host that has not answered in years;
      // Clogs logs the failure and carries on, which is what it does natively
      // on a machine with no network.
      const app = await bootApp(page, { entry: `/hh/samples/${name}.rb`, warmupMs });

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

test.describe("mouse-driven drawing", () => {
  test("Scribble is blank until something is scribbled on it", async ({ page }) => {
    const app = await bootApp(page, { entry: "/hh/samples/Scribble.rb" });
    expect(await countColours(page)).toBe(1);

    // Scribble does not draw from the motion event: its `animate` block reads
    // `self.mouse` and draws a segment if the button is down. So the drag has
    // to span frames, with the button still held while they happen.
    await app.drag([[60, 60], [100, 80], [140, 110], [180, 140]], { stepMs: 100 });

    expect(await countColours(page), "dragging drew nothing").toBeGreaterThan(1);
  });
});

test.describe("shapes", () => {
  test("a shape draws the art drawables written inside it", async ({ page }) => {
    // Lacci models `shape { arc ... }` as a slot holding an Arc drawable
    // rather than as a path command, and Clogs used to draw only the recorded
    // commands -- so samples/Arcs.rb, which is ten shapes of one arc each,
    // measured 0x0 and painted nothing but its background.
    const app = await bootApp(page, { entry: "/hh/samples/Arcs.rb" });

    const shapes = await app.find("Shape");
    expect(shapes.length).toBeGreaterThanOrEqual(10);
    for (const shape of shapes) {
      expect(shape.width, "a shape sized itself to nothing").toBeGreaterThan(0);
      expect(shape.height).toBeGreaterThan(0);
    }

    // And the arcs inside them are laid out, not left unmeasured.
    const arcs = await app.find("Arc");
    expect(arcs.length).toBeGreaterThanOrEqual(10);
    expect(arcs.every((arc) => arc.width > 0)).toBe(true);

    expect(await countColours(page)).toBeGreaterThan(1);
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

  test("an animation survives redrawing itself with `clear`", async ({ page }) => {
    // `animate { clear { ... } }` is how Shoes animations have always been
    // written, and `animate` is a drawable in the document like any other --
    // so clearing the slot used to destroy the very subscription driving it,
    // and Clock drew one frame and froze.
    const app = await bootApp(page, { entry: "/hh/samples/Clock.rb" });

    const subscriptions = () => app.ruby(`
      count = 0
      Clogs::App.instances.first.document_root.each_peer do |peer|
        count += 1 if peer.is_a?(Clogs::SubscriptionItem)
      end
      count.to_s
    `);
    expect(Number(await subscriptions())).toBe(1);

    const before = await page.evaluate(() => window.clogs.framesPainted());
    await app.advance(3000);

    expect(Number(await subscriptions()), "the animation was cleared away").toBe(1);
    expect(await page.evaluate(() => window.clogs.framesPainted())).toBeGreaterThan(before + 5);
  });

  test("rebuilding the document every frame does not get slower each frame", async ({ page }) => {
    // Every drawable subscribes to six events, and nothing used to take those
    // subscriptions back off: a destroyed slot left its children alive, and an
    // emptied handler list was left in a table that is scanned in full on
    // every unsubscribe. Arcs rebuilds twenty-one drawables forty times a
    // second, so the tenth second of animation cost six times the first.
    const app = await bootApp(page, { entry: "/hh/samples/Arcs.rb", warmupMs: 500 });

    const subscriptions = () => page.evaluate(() => Number(window.__clogsVM.eval(`
      handlers = Shoes::DisplayService.class_variable_get(:@@display_event_handlers)
      handlers.values.sum { |targets| targets.values.sum(&:size) }.to_s
    `).toString()));

    const before = await subscriptions();
    await app.advance(1500);
    const after = await subscriptions();

    // Flat, not merely slower-growing: the document is the same size each frame.
    expect(after, `subscriptions grew from ${before} to ${after}`).toBeLessThanOrEqual(before + 10);
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
