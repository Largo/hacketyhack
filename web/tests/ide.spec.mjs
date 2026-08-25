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

  test("reopening a program does not stack up its subscriptions", async ({ page }) => {
    // The editor rebuilds itself with `clear { draw_content script }` every
    // time a program is opened, and clearing a slot does not stop an
    // animation or a keypress handler -- it never did in Shoes either, which
    // is why HH::SideTabs::Prefs stops its own before clearing. Without the
    // same discipline here the second program opened would handle every
    // keystroke twice, and every open would leave another timer running.
    const app = await bootIDE(page);
    await clickSidebar(app, 1);

    const subscriptions = () => app.ruby(`
      counts = Hash.new(0)
      Clogs::App.instances.first.document_root.each_peer do |peer|
        counts[peer.api_name] += 1 if peer.is_a?(Clogs::SubscriptionItem)
      end
      counts.sort.map { |name, count| "#{name}=#{count}" }.join(" ")
    `);

    const before = await subscriptions();
    expect(before).toContain("keypress=1");
    expect(before).toContain("every=1");

    for (let i = 0; i < 3; i++) {
      await app.ruby(`HH::APP.gettab(:Editor).load({}); "ok"`);
      await app.advance(400);
    }

    expect(await subscriptions(), "subscriptions accumulated across opens").toBe(before);
  });

  test("backspace keeps deleting, and typing resumes after it", async ({ page }) => {
    // `para.cursor = :marker` is how the editor collapses a selection after
    // an edit, and it used to move the caret without clearing the marker.
    // The editor skips setting a marker when one is already there, so every
    // backspace after the first asked to delete a zero-length range and
    // silently did nothing.
    const app = await bootIDE(page);
    await clickSidebar(app, 1);

    await app.click(600, 300);
    await app.type("abcd");
    await app.advance(300);

    for (const expected of ["abc", "ab", "a"]) {
      await app.key("Backspace");
      await app.advance(200);
      expect(await app.texts()).toContain(expected);
    }

    // And the caret is where the deletions left it, not back at the marker.
    await app.type("XY");
    await app.advance(200);
    expect(await app.texts()).toContain("aXY");
  });
});
