import { test, expect } from "@playwright/test";
import { bootApp, bootIDE } from "./helpers.mjs";

// Shoes' `ask` returns its answer to the line that called it, and a page
// cannot block -- so Ruby parks the frame mid-program and the answer resumes
// it. These started out as window.alert and window.prompt, which do block, but
// a page cannot count on having them: an embedded webview may refuse prompt()
// outright, and then Hackety Hack's very first program does nothing at all.

async function openEditor(app) {
  const tabs = (await app.find("Image"))
    .filter((image) => image.x < 38 && image.width <= 24)
    .sort((a, b) => a.y - b.y);
  await app.click(tabs[1].centerX, tabs[1].centerY);
  await app.advance(800);
}

test.describe("dialogs", () => {
  test("`alert` from a program run in the editor puts a dialog on the page", async ({ page }) => {
    // If this ever falls back to window.alert, Playwright's native-dialog
    // channel sees it and this fails -- which is the point.
    const native = [];
    page.on("dialog", async (dialog) => {
      native.push(dialog.type());
      await dialog.accept();
    });

    const app = await bootIDE(page);
    await openEditor(app);

    await app.click(600, 300);
    await app.type('alert "hello from a program"');
    await app.advance(400);
    await app.clickText("Run");

    expect(await app.dialog()).toMatchObject({ message: "hello from a program", hasInput: false });
    expect(native, "fell back to the browser's own dialog").toEqual([]);

    await app.answerDialog();
    expect(await app.dialog()).toBeNull();
  });

  test("`ask` returns its answer to the line that called it", async ({ page }) => {
    const app = await bootIDE(page);
    await openEditor(app);

    await app.click(600, 300);
    await app.type('n = ask("your name?")');
    await app.key("Enter");
    await app.type('alert "hi " + n.to_s');
    await app.advance(400);
    await app.clickText("Run");

    expect(await app.dialog()).toMatchObject({ message: "your name?", hasInput: true });

    await app.answerDialog("Andi");

    // The second dialog is the proof: the program carried on past `ask` with
    // the answer in hand.
    expect(await app.dialog()).toMatchObject({ message: "hi Andi", hasInput: false });
    await app.answerDialog();
  });

  test("cancelling `ask` answers nil, as Shoes does", async ({ page }) => {
    const app = await bootIDE(page);
    await openEditor(app);

    await app.click(600, 300);
    await app.type('n = ask("anything?")');
    await app.key("Enter");
    await app.type('alert "got " + n.inspect');
    await app.advance(400);
    await app.clickText("Run");

    await app.cancelDialog();
    expect(await app.dialog()).toMatchObject({ message: "got nil" });
    await app.answerDialog();
  });

  test("the app keeps painting while a dialog is up, and input waits", async ({ page }) => {
    const app = await bootIDE(page);
    await openEditor(app);

    await app.click(600, 300);
    await app.type('alert "waiting"');
    await app.advance(400);
    await app.clickText("Run");
    expect(await app.dialog()).not.toBeNull();

    // Frames still happen -- the app does not go grey behind the dialog.
    const before = await page.evaluate(() => window.clogs.framesPainted());
    await page.evaluate(() => { window.clogs.pause(); });
    await app.ruby(`Clogs::App.instances.first.redraw!; "ok"`);
    await app.advance(200);
    expect(await page.evaluate(() => window.clogs.framesPainted())).toBeGreaterThan(before);

    // And the dialog is still the only thing that can be answered.
    expect(await app.dialog()).not.toBeNull();
    await app.answerDialog();
    expect(await app.dialog()).toBeNull();
  });

  test("a top-level ask, with no frame to park, uses the browser's dialog", async ({ page }) => {
    // Guessing Game is a bare ask/alert loop with no Shoes.app in it, so it
    // runs before there is a frame to suspend. That case still needs a
    // blocking dialog, and this pins which case it is.
    let answered = 0;
    page.on("dialog", (dialog) => {
      answered += 1;
      dialog.accept("50");
    });

    const app = await bootApp(page, { entry: "/hh/samples/Guessing Game.rb" });
    expect(answered).toBeGreaterThan(0);
    expect(await app.dialog(), "the in-page dialog was used before a frame existed").toBeNull();
  });
});
