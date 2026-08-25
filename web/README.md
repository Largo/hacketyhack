# Hackety Hack in a browser

The same Hackety Hack that `ruby hacketyhack.rb` runs, running on CRuby
compiled to WebAssembly, painting into a `<canvas>`, and drivable from
Playwright.

Nothing about the app is ported or reimplemented. `app/`, `lib/`, `samples/`
and `lessons/` are shipped byte for byte into a filesystem the browser holds in
memory, and Clogs gets one more display backend — `CLOGS_BACKEND=wasm`, in
[`clogs/lib/clogs/wasm/`](../clogs/lib/clogs/wasm) — alongside libui, Qt, GTK3,
FOX, wx and NAppGUI. A bug you find here is the bug the desktop app has.

```
npm install                # once
bundle install             # once, for web/Gemfile (the gems packed into wasm)
npm run serve              # http://localhost:4173
npm test                   # the Playwright suite
```

CI runs the same suite on every push and pull request — the `wasm` job in
[`.github/workflows/ci.yml`](../.github/workflows/ci.yml). On failure it
uploads the Playwright report and traces, which is worth having when the whole
UI is one canvas.

`npm run serve` rebuilds the bundle first. After changing any Ruby that the
browser loads, re-run `npm run build` (or just `npm run serve` again) — the
`.rb` files are packed into `dist/vfs.bin`, not read off disk.

Open a bundled Shoes program instead of the IDE with `?entry=`:

    http://localhost:4173/?entry=/hh/samples/Clock.rb

## Writing a test

Clogs paints the whole Shoes document into one canvas, so there are no
elements to select and no text for Playwright to read. `window.clogs` is the
way in: it answers with the drawable tree — every drawable's Shoes class, its
absolute position and the words on it — delivers input to the app rather than
to the DOM, and hands the test the frame clock.

```js
import { test, expect } from "@playwright/test";
import { bootIDE } from "./helpers.mjs";

test("the samples tab lists the samples", async ({ page }) => {
  const app = await bootIDE(page);

  await app.clickText("Samples");
  await app.advance(500);

  expect(await app.texts()).toContain("Clock");
  app.expectNoErrors();
});
```

`bootApp(page, { entry })` boots any program; `bootIDE(page)` boots the IDE and
clicks past its splash screen.

| what | for |
|---|---|
| `describe()` | the whole drawable tree, with geometry |
| `find(text)` / `texts()` | drawables matching some words, or all the words |
| `clickText(text)`, `click(x, y)` | a click the app receives, by name or by point |
| `drag(points, { stepMs })` | press, move, release — `stepMs` runs frames mid-drag |
| `type(text)`, `key(name)` | keystrokes |
| `advance(ms)`, `tick(n)`, `settle()` | the frame clock, turned by hand |
| `ruby(source)` | evaluate Ruby inside the running app |
| `expectNoErrors()` | assert nothing was logged to the console |

**The clock belongs to the test.** `bootApp` pauses the page's own animation
frames, so nothing moves except when the test says so: `advance(1000)` is one
second of the app's animations, timers and sleeping threads, on any machine,
and `page.waitForTimeout` is one second of nothing happening. That is what
makes a canvas test reproducible instead of a race. Pass `paused: false` to
watch it run in real time instead.

`ruby(source)` runs in the same VM the app is in, which is usually the fastest
way to answer "what does the app think its state is":

```js
await app.ruby(`Clogs::App.instances.first.document_root.children.size.to_s`);
```

## How it fits together

| | |
|---|---|
| `boot.js` | fetches CRuby and the bundle, mounts the filesystem, starts Ruby |
| `boot.rb` | the first Ruby that runs: load path, working directory, then the app |
| `host.js` | owns the canvas: replays the command buffer, queues input, exposes `window.clogs` |
| `build.mjs` | packs every `.rb` and asset into `dist/vfs.bin` and bundles `boot.js` |
| `vfs.mjs` | the bundle format, shared by the builder and the page |
| `persist.mjs` | mirrors the wasm home directory into localStorage |

## Dialogs

`ask`, `alert` and `confirm` are elements on the page, not the browser's own
dialogs. Shoes' `ask` returns its answer to the line that called it and a page
cannot block, so Ruby parks the frame mid-program and the answer resumes it —
see `Clogs::Wasm::Runtime#modal`. While one is up the app keeps painting but
takes no input, which is what `ask` does in Shoes: it stops the program where
it stands.

They used to be `window.prompt` and friends, which *do* block. A page cannot
count on having them — an embedded webview may answer `prompt() is not
supported` — and then Hackety Hack's first program does nothing at all. The
window.* versions remain for the one case that cannot park: code running
before there is a frame to park, like `samples/Guessing Game.rb`, whose whole
program is a top-level ask loop with no `Shoes.app` in it.

Tests drive them the way a person does: `app.dialog()`, `app.answerDialog(text)`
and `app.cancelDialog()`.
| `serve.mjs` | a static server, with the CRuby binary mapped in from `node_modules` |
| `shims/` | the C extensions wasm cannot have: sqlite3, nokogiri, net/http, openssl |
| `Gemfile` | the three pure-Ruby gems packed into the wasm filesystem, pinned |

`web/Gemfile` is separate from the repo's own on purpose, and the comment in it
says why: the repo takes Scarpe from git for the webview backend, and Scarpe's
repo is a monorepo carrying Lacci's gemspec, so Bundler resolves Lacci from git
for the whole project too. That is a different Shoes from the released 0.5.0
Hackety Hack's compatibility layer is written against, and this suite is what
found the difference — on git main the IDE's side tabs stop opening. So the
browser states which Shoes it runs instead of inheriting it.

Ruby and the page talk exactly twice per frame — input and the clock in, one
command buffer out — because a call across the wasm boundary costs about ten
microseconds and a frame of Hackety Hack is thousands of drawing operations.
`clogs/lib/clogs/wasm/painter.rb` and `host.js` hold the two halves of the
opcode table; they have to agree.

## Sizing

A Shoes window resizes unless the program says otherwise, so a resizable app is
given the whole page and told to lay out again — Hackety Hack asks for 790x550
and gets whatever the browser window is. A program that opts out
(`Shoes.app :resizable => false`, as `samples/Arcs.rb` does) keeps the size it
asked for. Nothing is ever scaled: the backing store is sized for the display's
density, so text stays sharp on a retina screen.

It never goes *below* the declared size, though. That is the size the layout
was written against, and under it things overlap rather than reflow — so a
small window gets the app at its own size and page scrollbars to reach the rest
of it.

## What is kept

The wasm filesystem is built fresh on every load, so anything written to it
would be gone on reload. The home directory — where Hackety Hack keeps
`~/.hacketyhack`, which is to say your programs — is mirrored into
localStorage: restored before Ruby starts, saved when it changes and when the
tab goes away. Only that subtree, since the app and its samples are shipped in
the bundle already. `web/persist.mjs` has the details, including what happens
if it outgrows localStorage.

## What is not there

- **No sockets.** Everything Hackety Hack does over the network goes to
  hackety.org, which has not answered since 2013, so `net/http` raises the same
  `SocketError` an offline machine raises and the app takes the same paths.
- **No file pickers.** `ask_open_file` and friends return nil. A page cannot
  wait for a file picker synchronously, and Shoes' API is synchronous.
- **No preemptive threads.** `Thread.new` becomes a Fiber scheduled between
  frames, and `sleep` and `Queue#pop` yield to it. A thread that never yields
  hangs the page, exactly as an endless event handler would.
- **The system clipboard is one-way.** Copy and paste inside a Shoes program
  work; pasting something copied from another application does not.
