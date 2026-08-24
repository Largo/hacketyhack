import { test, expect } from "@playwright/test";
import { bootIDE } from "./helpers.mjs";

// Hackety Hack's side tabs are a column of 16x16 icons down the left edge,
// with no text on them -- so they are found by position in that column rather
// than by name. Top to bottom: Home, Editor, Lessons, and the rest.
async function sidebarTabs(app) {
  const images = await app.find("Image");
  return images
    .filter((image) => image.x < 38 && image.width <= 24)
    .sort((a, b) => a.y - b.y);
}

async function clickSidebar(app, index) {
  const tabs = await sidebarTabs(app);
  expect(tabs.length, "the side tab column is missing").toBeGreaterThan(index);
  await app.click(tabs[index].centerX, tabs[index].centerY);
  await app.advance(800);
  return tabs[index];
}

test.describe("the Home tab", () => {
  test("lists the user's programs and switches to the samples", async ({ page }) => {
    const app = await bootIDE(page);

    expect(await app.texts()).toContain("Programs");
    expect(await app.texts()).toContain("Hello World");

    await app.clickText("Samples");
    await app.advance(500);

    const texts = await app.texts();
    expect(texts).toContain("Clock");
    expect(texts).toContain("Arcs");
    // The sample list pages five at a time.
    expect(texts.join(" ")).toContain("Next 5");

    app.expectNoErrors();
  });

  test("paging through the samples changes the list", async ({ page }) => {
    const app = await bootIDE(page);
    await app.clickText("Samples");
    await app.advance(500);

    const firstPage = await app.texts();
    await app.clickText("Next 5");
    await app.advance(500);
    const secondPage = await app.texts();

    expect(secondPage).not.toEqual(firstPage);
    app.expectNoErrors();
  });
});

test.describe("the side tabs", () => {
  test("Home, Editor and Lessons each open something different", async ({ page }) => {
    const app = await bootIDE(page);

    await clickSidebar(app, 1);
    expect((await app.texts()).join(" "), "the Editor tab").toContain("New Program");

    await clickSidebar(app, 2);
    expect((await app.texts()).join(" "), "the Lessons tab").toContain("A Tour of Hackety Hack");

    await clickSidebar(app, 0);
    expect((await app.texts()).join(" "), "the Home tab").toContain("Programs");

    app.expectNoErrors();
  });
});

test.describe("the editor", () => {
  test("takes typed text and notices the program is unsaved", async ({ page }) => {
    const app = await bootIDE(page);
    await clickSidebar(app, 1);

    expect((await app.texts()).join(" ")).toContain("Not yet saved.");
    // There is no Save button until there is something to save.
    expect(await app.texts()).not.toContain("Save");

    await app.click(600, 300);
    await app.type("puts 42");
    await app.advance(500);

    const texts = await app.texts();
    expect(texts, "the typed text is not in the editor").toContain("puts 42");
    expect(texts, "editing did not mark the program dirty").toContain("Save");

    app.expectNoErrors();
  });

  test("backspace deletes a character", async ({ page }) => {
    const app = await bootIDE(page);
    await clickSidebar(app, 1);

    await app.click(600, 300);
    await app.type("abcd");
    await app.advance(300);
    expect(await app.texts()).toContain("abcd");

    await app.key("Backspace");
    await app.advance(300);
    expect(await app.texts()).toContain("abc");
  });

  test("a second backspace does nothing -- the editor only deletes once", async ({ page }) => {
    // A real bug in Hackety Hack's editor, not in the way the browser
    // delivers keys: dispatching the same `keypress` event straight from Ruby,
    // which is exactly what the native backends do, deletes nothing either,
    // while typing an ordinary character still works. So the editor is losing
    // something about its own state after one delete.
    //
    // When this is fixed, this test fails -- change it to assert "ab".
    const app = await bootIDE(page);
    await clickSidebar(app, 1);

    await app.click(600, 300);
    await app.type("abcd");
    await app.advance(300);

    await app.key("Backspace");
    await app.advance(200);
    await app.key("Backspace");
    await app.advance(200);
    expect(await app.texts(), "backspace repeats now -- this bug is fixed").toContain("abc");

    // Typing still lands, so it is delete specifically that is stuck.
    await app.type("z");
    await app.advance(200);
    expect(await app.texts()).toContain("abcz");
  });
});
