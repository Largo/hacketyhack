import { test, expect } from "@playwright/test";
import { bootIDE } from "./helpers.mjs";

// Hackety Hack ships eight lesson sets, and the tutor is most of what a
// beginner actually uses. These check the parts that broke quietly: opening
// the right one, paging through it, and running the code it offers.

const LESSON_SETS = [
  "1: A Tour of Hackety Hack",
  "2: Basic Programming",
  "3: Basic Ruby",
  "4: Basic Shoes",
  "5: Better Guessing Game",
  "Beginner Data Structures",
  "Data Types",
  "Fun with Arrays",
];

async function openLessonsTab(app) {
  const sideTabs = (await app.find("Image"))
    .filter((image) => image.x < 38 && image.width <= 24)
    .sort((a, b) => a.y - b.y);
  await app.click(sideTabs[2].centerX, sideTabs[2].centerY);
  await app.advance(1000);
}

// The tutor's Next button: the right-hand of the two small icons in its
// bottom bar.
async function nextButton(app) {
  const tree = await app.describe();
  const flat = [];
  (function walk(node) { if (!node) return; flat.push(node); (node.children || []).forEach(walk); })(tree.drawables);
  const icons = flat
    .filter((n) => n.width === 16 && n.height === 16 && n.y > tree.height - 70 && n.x > 200)
    .sort((a, b) => a.x - b.x);
  const last = icons[icons.length - 1];
  return last && { x: last.x + last.width / 2, y: last.y + last.height / 2 };
}

test.describe("the lesson tutor", () => {
  test("the Lessons tab lists every lesson set", async ({ page }) => {
    const app = await bootIDE(page);
    await openLessonsTab(app);

    const texts = await app.texts();
    for (const name of LESSON_SETS) expect(texts).toContain(name);
  });

  test("each lesson set opens the lesson it names", async ({ page }) => {
    // Every set is a link in a paragraph as wide as the sidebar, so the words
    // are only the left part of it. Clicking the middle of the box used to
    // miss the short names entirely and silently leave the previous lesson up.
    const app = await bootIDE(page);

    for (const name of LESSON_SETS) {
      await openLessonsTab(app);
      await app.clickText(name);
      await app.advance(1200);

      const opened = await app.ruby(`
        set = HH::LessonSet.class_variable_get(:@@open_lesson)
        set ? set.instance_variable_get(:@name).to_s : "none"
      `);
      expect(opened, `clicking "${name}" opened "${opened}"`).toBe(name);
    }
  });

  test("paging through a lesson shows a new page each time", async ({ page }) => {
    const app = await bootIDE(page);
    await openLessonsTab(app);
    await app.clickText("4: Basic Shoes");
    await app.advance(1200);

    const paneText = async () =>
      (await app.find(/[^]/)).filter((hit) => hit.x > 600).map((hit) => hit.text).join(" | ");

    const next = await nextButton(app);
    expect(next, "the tutor has no Next button").not.toBeNull();

    const first = await paneText();
    const seen = new Set([first]);
    for (let i = 0; i < 11; i++) {
      await app.click(next.x, next.y);
      await app.advance(500);
      const text = await paneText();
      expect(text.trim(), "a lesson page rendered blank").not.toBe("");
      seen.add(text);
    }
    // Basic Shoes has twelve pages; they should not all be the same one.
    expect(seen.size).toBeGreaterThan(8);

    app.expectNoErrors();
  });

  test("the tour's Run this button runs the program it shows", async ({ page }) => {
    // `alert "Hello, world!"` is the first program Hackety Hack teaches, and
    // the tour offers to run it for you.
    const native = [];
    page.on("dialog", async (dialog) => { native.push(dialog.type()); await dialog.accept(); });

    const app = await bootIDE(page);
    await openLessonsTab(app);
    await app.clickText("1: A Tour of Hackety Hack");
    await app.advance(1200);

    const next = await nextButton(app);
    let found = false;
    for (let i = 0; i < 14 && !found; i++) {
      if ((await app.find("Run this")).length) found = true;
      else { await app.click(next.x, next.y); await app.advance(400); }
    }
    expect(found, "no page in the tour offers to run anything").toBe(true);

    await app.clickText("Run this");
    await app.advance(400);
    expect(await app.dialog()).toMatchObject({ message: "Hello, world!" });
    expect(native, "fell back to the browser's own dialog").toEqual([]);
    await app.answerDialog();
  });
});
