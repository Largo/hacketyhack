# Which display library should Shoes sit on?

Clogs paints the whole Shoes document itself and uses its display library for
three things only: a window, a drawing surface and an event source. That
boundary is narrow enough to write more than once, so it has been -- against
libui, FOX, wxWidgets, Qt, GTK3 and NAppGUI -- and all six run the same
programs, so they can be compared by measurement rather than by argument.

There is a seventh, `wasm`, which is not a library at all: it is a browser
canvas, reached from CRuby compiled to WebAssembly. It runs the same programs
too. It is documented at the end, because almost nothing in the comparison
below applies to it.

```
CLOGS_BACKEND=libui   ruby hacketyhack.rb  # the default
CLOGS_BACKEND=fox     ruby hacketyhack.rb
CLOGS_BACKEND=wx      ruby hacketyhack.rb
CLOGS_BACKEND=qt      ruby hacketyhack.rb  # needs clogs/ext/qt/build.sh first
CLOGS_BACKEND=gtk3    ruby hacketyhack.rb
CLOGS_BACKEND=nappgui ruby hacketyhack.rb  # needs clogs/ext/nappgui/build.sh
rake compare                               # the benchmark table below
cd web && npm run serve                    # CLOGS_BACKEND=wasm, in a browser
```

**Short answer: libui's weaknesses are libui's, not its stack's — and the
cheapest way to fix them is gtk3.** On Linux libui *is* GTK3 and Cairo, one C
wrapper down. Reaching the same libraries directly makes the same picture
thirty-five times cheaper to draw and stops it being downsampled, without
changing a pixel of what Shoes programs look like. Qt draws the best frame overall and wx
is the most portable of the alternatives; libui stays the default because it
is the only one that installs without a compiler. NAppGUI is the smallest and
newest of the six and draws as well as any of them — and is the only one that
cannot host a text editor, because its key event has no character in it.

## The measurement

`rake compare` paints a Shoes document repeatedly for five seconds with a 60fps
animation driving the repaints, and reports the median time to paint one whole
frame.

| page | libui | fox | wx | qt | gtk3 | nappgui |
|---|---|---|---|---|---|---|
| no image (control) | 0.98 ms | **0.34 ms** | 1.11 ms | 0.69 ms | 0.67 ms | 0.62 ms |
| 16×16 icon | 1.40 ms | **0.22 ms** | 0.26 ms | 0.49 ms | 0.45 ms | 0.39 ms |
| 500×616 art (`hhhello.png`) | 8.77 ms | **0.20 ms** | 0.98 ms | 0.73 ms | 1.10 ms | 1.17 ms |
| 256×256 art with alpha (`splash-hand.png`) | 18.75 ms | **0.19 ms** | 0.46 ms | 0.59 ms | 0.54 ms | 0.57 ms |
| 40 styled paragraphs | 50.87 ms | **9.11 ms** | 52.05 ms | 14.24 ms | 34.90 ms | 16.80 ms |

**The libui and gtk3 columns are the interesting pair.** They are the same
Cairo and the same Pango: on Linux libui is a C wrapper over exactly this. Yet
gtk3 paints the alpha art thirty-five times faster and the text page in two
thirds the time, and draws the large art at full resolution where libui
downsamples it. Every one of libui's weaknesses in this document is the
wrapper's, not the stack's.

Read the image rows against the control: the difference is what putting a
picture on the page costs.

**libui cannot blit.** It exports no draw-image call, so that backend decodes
PNGs itself and paints them as run-length encoded rectangles. It is about as
clever as it can be about that — merging identical rows, grouping into one path
per colour, caching the paths across frames — and a single 256×256 picture
still costs 18 ms, which is a whole frame at 60fps, after a 416 ms first frame
spent building the paths. The other two blit, and their cost barely moves with
the size of the picture.

**FOX is fastest because it does the least.** Its blit is `XPutImage` with no
compositing, which is why it is several times quicker than the rest at getting
a bitmap onto the screen and also why it cannot honour that bitmap's alpha. The
speed and the fidelity loss are the same fact.

**wx and libui draw text at exactly the same speed**, because it is the same
Pango, and both are three times slower than Qt and two thirds the speed of
gtk3 at it. That 50 ms is a property of neither library: Clogs rebuilds a text
layout object per styled run per frame, and caching those is the single
biggest improvement available to either. FOX, Qt and NAppGUI are quicker
because none of them builds a layout object at all — they ask for a string's
width and draw it.

**NAppGUI lands in the same band as Qt, wx and gtk3** on every page — quickest
of the four on the control page, third overall on text behind FOX and Qt, and
last of the five non-libui backends on the large artwork. Against libui it is
thirty-three times faster on the alpha art and three times faster on text, and
unlike FOX it antialiases, composites alpha properly and has a real transform.
It is thin over the platform's drawing API the way FOX is — on Linux that is
Cairo again — without giving up what Cairo can do.

Cold start with the 488×1407 `hhcheat.png`: libui 1.50 s, FOX 0.54 s.

**libui also draws large art at reduced resolution**, which the frame timings
do not show. Its encoder gives up at 40,000 rectangles and then samples every
second pixel: `hhcheat.png` needs 66,455 runs at full resolution and
`hhhello.png` 100,183, so both are downsampled. Hackety Hack's Cheat Sheet is
legible on every other backend and smeared on libui.

## What each one gives up

| Shoes needs | libui | FOX | wx | qt | gtk3 | nappgui |
|---|---|---|---|---|---|---|
| Blit a bitmap | **no** — rectangles | yes | yes | yes | yes | yes |
| Draws large art at full resolution | **no** — samples every 2nd pixel | yes | yes | yes | yes | yes |
| Composite image alpha | yes | **no** — 1-bit shape mask | yes | yes | yes | yes |
| Antialiasing | yes | **no** | yes | yes | yes | yes |
| Transform stack (`rotate`, `scale`, `skew`) | yes | **no** — in Ruby, geometry only | yes | yes | yes | yes |
| Rotate text and images | yes | **no** | yes | yes | yes | yes |
| Gradients | yes | **no** — banded by hand | yes | yes | yes | yes |
| Rectangular clipping | yes | yes | yes | yes | yes | **no** — offscreen bitmaps |
| Arbitrary path clipping | yes | region only | yes | yes | yes | **no** |
| Even-odd fill rule | yes | yes | yes | yes | yes | **no** — winding only |
| A path object | yes | **no** — flattened in Ruby | yes | yes | yes | **no** — flattened in Ruby |
| Strikethrough, for `del()` | **no** | yes | yes | yes | yes | yes |
| A character in the key event | yes | yes | yes | yes | yes | **no** — see below |
| Image formats | **PNG only** (chunky_png) | 10 formats | 10 formats | 10+ formats | everything GdkPixbuf reads | 4 — PNG, JPG, BMP, GIF |
| Caret geometry, per-character positions | **no** | measures substrings | `get_partial_text_extents` | `QTextLayout` | `Pango#xy_to_index` | measures substrings |
| Second top-level window | **no** | yes | yes | yes | yes | yes |
| Inner slot scrolling | **no** | `FXScrollArea` | `wxScrolledWindow` | `QScrollArea` | `Gtk::ScrolledWindow` | `view_scroll` |
| Native clipboard | **no** — shells out | yes | yes | yes | yes | **no** — per-control only |
| Native `ask` dialog | **no** — hand-built | yes | yes | yes | hand-built (GTK has none) | hand-built (no message box) |
| A real text editor widget | **no** | `FXText`, Scintilla | `wxTextCtrl`, Scintilla | `QPlainTextEdit` | `Gtk::TextView` | `TextView` |
| Places a native control at (x, y) | **no** | yes | yes | yes | `Gtk::Fixed` | **no** — grid layouts only |
| A Ruby binding that exists | yes | yes | yes | **no** — see below | yes | **no** — see below |

`tools/bench_fidelity.rb` draws every disputed case on one page. Run it under
each backend and compare: libui, wx, qt, gtk3 and nappgui are indistinguishable
from one another apart from libui's missing strikethrough, and FOX differs in
exactly the ways the table predicts — stepped edges on the star and the ovals,
and two overlapping translucent discs that do not blend.

The IDE itself matches too. Comparing `tools/screenshots.rb` output against
gtk3 pixel by pixel, the Cheat Sheet pane is byte-identical and the others
differ only in the antialiased edges of glyphs drawn inside a clipped slot,
where the text is antialiased against the offscreen bitmap rather than against
what is behind it — 2% of the pixels of a pane, all of them on a glyph edge.

`tools/screenshots.rb` does the same for the IDE itself, driving it through its
own `opentab` and photographing every pane on whichever backend is selected.

## What it took to make each one work

All six now do the same thing:

```
                              libui     fox      wx      qt    gtk3  nappgui
rake samples                  11/12    11/12   11/12   11/12   11/12    11/12
rake boot                        ok       ok      ok      ok      ok       ok
cd clogs && rake test         15/15    15/15   12/15   15/15   15/15    12/15
                                                + 3 skipped        + 3 skipped
```

The failing sample is `Guessing Game.rb` on all six, for the reason the
Rakefile already documents: it calls `ask` in an unattended loop and headless
CI has nobody to answer it. On nappgui it fails one step earlier and for a
second reason — see below.

The three skipped tests are wx's and nappgui's, and the skip is honest in both
cases: they measure text, and neither library can build a font before its main
loop is running — wx because its application object does not exist until then,
NAppGUI because `osmain_imp` has not started draw2d. The other four need only a
display. Finding this needed a fix to the shared test helper, which had been
deciding a backend could measure text if the call did not raise: NAppGUI's
answers zero rather than failing, so the tests ran and then failed on the
zero.

### FOX

- **Tearing a window down from inside a draw handler.** Fractal's turtle
  finishes drawing and quits, so the document finishes painting with no canvas
  left to blit onto. Constructing an `FXDCWindow` on a destroyed drawable
  aborts the process, and freeing the back buffer while a context is still open
  on it produces `BadDrawable` storms.

### wx

Every one of these was a hang or a crash, and none of them was obvious:

- **wx's error log is a modal dialog.** wxWidgets reports a PNG it cannot
  decode through a log target that, in a GUI program, defaults to a message
  box. Nobody is there to dismiss it, so one unreachable image URL stops the
  program forever holding the event loop — and Ruby's background threads starve
  along with it, because the GVL never comes back. Funnies hung on exactly
  this. The backend now sends wx's log to stderr.
- **Starting a throwaway application unregisters every image handler.**
  wxWidgets registers its image loaders when an application starts and drops
  all of them when one exits, without ever putting them back. Shoes' `font`
  builtin is called at load time, before any app exists — Hackety Hack calls it
  five times from the top of its boot — and answering that by spinning up a
  temporary application left the real one unable to load a single PNG. The
  builtins that need no GUI are now answered without one.
- **wx's stock objects are not safe to hand to a graphics context.** Passing
  `Wx::TRANSPARENT_PEN` or `Wx::BLACK` to `set_pen` or `set_font` corrupts a
  reference count: wx reports "invalid ref data count" from `DecRef`, and then
  the process dies. Clogs builds its own equivalents. Caching *ordinary* wx
  colours, brushes, pens and fonts turned out to be fine, and is necessary —
  without the font cache a page of forty paragraphs costs 1097 ms a frame
  instead of 68 ms.
- **`wxColour` rejects channels given as floats** and then asserts on every
  later use of the colour, so colours are normalised in one place.
- **Loading wx binds Nokogiri to the system libxml2.** Nokogiri carries its own
  inside its precompiled extension, wxWidgets links the distribution's, and
  whichever loads first wins — 2.9.14 against the 2.13.9 Nokogiri was built
  for, on Ubuntu 24.04. Hackety Hack's compatibility layer now requires
  Nokogiri first.
- **`finish` blocks ran too late.** Hackety Hack ran them from `at_exit`, after
  wx has taken its world down with the event loop, so any drawable they touched
  raised `NameError`. They now run as the app is destroyed, which is both
  closer to Shoes 3 and the only moment at which they can do anything.
- **Every wx app exited the instant it opened**, and the test suite could not
  see it. wxWidgets reads the value of its init block as `OnInit`'s return, and
  anything falsy tears the application down rather than entering the main loop.
  That block ended in `install_test_hooks`, which returns a timer when
  CLOGS_EXIT_AFTER_MS is set and nil otherwise — so the backend ran perfectly
  under the harness and quit after a second everywhere else. `rake boot` passed
  throughout, because the app did shut down cleanly, for the wrong reason. It
  was found by trying to photograph the IDE.

### qt

Qt itself gave little trouble; the awkwardness was all at the
edges.

- **`QApplication::quit()` never returns for a Clogs window.** It asks every
  window to close first, and Clogs' windows refuse a close they did not
  initiate — the Shoes app decides when it is really going — so quit waits
  forever on a window that will never agree, and the X connection eventually
  drops underneath it. `QCoreApplication::exit(0)` is what was meant.
- **An arc that opens a figure is not the same as one that continues it.**
  libui distinguishes them and Clogs' rounded rectangles rely on it: the first
  corner opens the figure, the other three connect to it. Qt has only `arcTo`,
  which always draws a line from wherever the path currently is, so every
  button grew a spike back to the origin until the shim was told which of the
  two it was being given.
- **Qt reports libpng's opinion of every PNG it loads**, and libpng has an
  opinion about half the PNGs on the internet. Neither a logging rule nor
  `QT_LOGGING_RULES` silences it; a message handler does.
- **Qt warns when `XDG_RUNTIME_DIR` is unset**, which it is on any headless
  server, and then warns again if the directory it is pointed at is not mode
  0700.

### gtk3

The least work of the six, which is the point: this is the library Clogs was
already drawing through, so nothing had to be approximated and Cairo's angles,
fill rules and transforms are the ones Clogs' shapes are written against.

- **`Gtk.init` does not exist, `Gtk.init_check` segfaults.** ruby-gnome
  initialises GTK as the binding loads; `require "gtk3"` is the whole of it,
  and calling the leftover check afterwards takes the process down.
- **`Gtk.main` and `Gtk.main_quit` are gone** from ruby-gnome 4. The loop they
  wrapped is GLib's, so the backend runs `GLib::MainLoop` directly.
- **Removing a GLib source twice is a GLib-CRITICAL on stderr**, not a Ruby
  exception, so it cannot be rescued -- only avoided. A timeout that returns
  false has already removed itself, and Fractal quits from inside its own
  animation, so the backend tracks which of its timers are still live.

### nappgui

NAppGUI is the youngest library here by two decades, and it shows in both
directions: the drawing API is clean and complete enough that the painter is
the shortest of the six, and the parts around it assume they own the program.

- **It wants to own `main()`.** `osmain` is a macro that *defines* `main()` and
  hands the process to the SDK. Ruby already has a `main()`, so that is not
  available. The macro expands to `osmain_imp`, an ordinary exported function,
  and calling that directly works — the SDK runs happily inside a process it
  did not start.
- **Nothing draw2d owns can be built before that call.** Not a font, not a
  window, not an image: creating a font before `osmain_imp` starts the SDK
  segfaults. A Shoes program builds its whole drawable tree first and then
  runs, so the backend defers the window to NAppGUI's create callback, defers
  image decoding to the first paint, and answers a zero extent for text
  measured too early. It is the only backend where `Shoes.app` cannot make its
  window in `init`.
- **There is no clipping. At all.** No rectangle, no region, no path — draw2d
  simply has no clip. Clogs needs one for a sized slot, an edit line and an
  edit box, so a clip here is an offscreen bitmap the size of the clip
  rectangle, drawn into and blitted back; a bitmap has edges, which is the
  whole of what a clip rectangle is. That works exactly, and it costs an
  allocation and a blit per clip per frame — 2.1 ms a frame on the benchmark
  page until the backend learned to skip a clip that cuts nothing off. Shoes'
  root slot has an explicit size, so *every* document asks to be clipped to its
  own window once a frame; recognising that one case took the control page from
  2.83 ms to 0.62 ms.
- **The key event has no character in it, and cannot be given one.** NAppGUI
  reports a `vkey_t` from a fixed table of GDK keysyms built around a Spanish
  keyboard. A US-layout `=`, `[`, `]`, `/`, `\` or backtick maps to no vkey at
  all, so it is not that those keys arrive wrongly — they do not arrive. No
  text editor can be written on that, which is most of what Hackety Hack is.
  The shim therefore reaches past NAppGUI to GTK and reads the keysym itself,
  where the keyboard layout has already been applied.
- **And it has to be a key snooper, not a handler.** NAppGUI's window connects
  its own `key-press-event` when the window is created, before this shim has a
  toplevel to connect to, and it takes Tab, Return and Escape for focus cycling
  and returns without passing them on. `gtk_key_snooper_install` is deprecated
  and is the only thing that runs earlier. This is the least portable code in
  any of the six backends, and the honest way to read it is that NAppGUI's
  keyboard model fits the form-and-button applications it is designed for and
  not a text editor.
- **Destroying a window from inside its own draw callback takes the process
  down**, the same hazard libui's `queue_main` exists for. A Shoes app that
  animates checks its run deadline from the paint callback, so this happened on
  every animated sample at once: `dctx_unset_gcontext` on a context that had
  just been freed underneath it. The backend defers the teardown to the next
  tick.
- **NAppGUI narrates its own life on stdout** — a startup line, a log file
  under the user's config directory, and a heap-leak audit on the way out. A
  Shoes program's own output should be the only thing a Shoes program prints,
  and Clogs' suites read anything else as a failure, so the shim turns it off.
  `CLOGS_NAP_LOG=1` puts it back.
- **`drawop_t` starts at 1, and `ekSTROKE` is first.** Assuming the C
  convention of a zero-based enum with fill first produced a window in which
  only outlines appeared — which is at least a fast way to find out.

Four shared bugs also fell out of writing the display half six times:

- **Paragraph reported a wrapped paragraph wider than the width it was asked to
  wrap at**, because it measured to the pen position rather than to the last
  glyph, counting the trailing space its own wrap decision already ignores. The
  backends' fonts differ there, which is what exposed it.
- **The test helper booted the display through a libui-only call**, so every
  test needing a display skipped silently on any other backend.
- **And it then decided a backend could measure text if the call did not
  raise.** NAppGUI's answers a zero extent before its SDK is up rather than
  failing, so the tests that need measurement ran and failed on the zero. The
  probe now judges measurement by its answer.
- **Hackety Hack's sidebar tabs could not be clicked on any backend.** Six
  backends behaving identically is a good way to tell a display bug from one
  that is not: this is not. Two things had to be true and neither was. Shoes 3 attaches a handler
  with `image(icon).click { }`, and the compatibility layer subscribed to the
  drawable's click event without setting the `:click` style that
  `Clogs::Image#clickable?` reads -- so the icon was never hit-tested and the
  subscription never fired. Underneath that, every slot was clickable by
  default, so a full-window slot painted after the sidebar won the hit test
  and swallowed the click anyway. A slot is now a click target only if
  something is listening for one; handlers on enclosing slots still fire,
  because a release bubbles up from the drawable that was pressed.

## The cost of the dependency

This is what argues for keeping libui as the default.

**libui** ships prebuilt binaries for Linux, macOS and Windows. `bundle
install` and it works, which for a program meant to be handed to a beginner is
most of the point.

**FXRuby** is a C++ extension needing FOX 1.6's headers: `libfox-1.6-dev`, plus
`libxrandr-dev`, which the build does not name and fails at the link step
without. About ninety seconds. FOX 1.6 is stable to the point of dormancy and
looks like a 2005 X11 application — which does not matter here, because Clogs
paints its own widgets.

**wxRuby3** is heavy:

- SWIG, doxygen and wxWidgets 3.2's headers. On Ubuntu that is
  `libwxgtk3.2-dev`, `libwxgtk-webview3.2-dev` and `libwxgtk-media3.2-dev` —
  the last two of which the gem does not name and fails to link without.
- A post-install `wxruby setup` that generates and compiles some two hundred
  C++ sources. Minutes, not seconds.
- **It does not build against a distribution's wxWidgets without a patch.**
  `wx-config --ld` on Debian and Ubuntu answers `g++ -o`, the trailing `-o`
  being meant to precede the output file directly. wxRuby3 appends its own
  `-o target` at the end of the link line, so that leading `-o` swallows the
  next flag (`-Wl,-soname,...`) and the shared object is never produced.
  Building it here needed a one-line change to
  `rakelib/lib/config/unixish.rb` to strip the trailing `-o`.

**Qt** is the heaviest, and differently so: there is nothing to install,
because there is nothing to install. The only Qt binding on rubygems is
`qtbindings`, which is Qt 4.8, last released in 2016, and unbuildable on any
distribution that has dropped Qt 4 — which Ubuntu did after 20.04. `ruby-qml`
is gone. So this backend ships its own C surface over Qt in
[`clogs/ext/qt/`](../ext/qt), about five hundred lines of C++ exposing the same
shape of API libui offers as a library, and calls it through Fiddle:

```
sudo apt-get install qt6-base-dev
clogs/ext/qt/build.sh
CLOGS_BACKEND=qt ruby hacketyhack.rb
```

That is a real cost — a backend nobody else maintains, in a language the rest
of the project is not written in — and it is the reason Qt is not the
recommendation despite drawing the best frame. It is also, oddly, the most
*self-contained* of the alternatives bar NAppGUI: one .cpp file and a two-line build,
against wxRuby3's SWIG-generated extension and its patch.

**GTK3** is the mildest of the alternatives: ruby-gnome's binding is a C
extension over the GTK 3 development files, which on Linux are already
installed, because libui needs GTK at runtime anyway.

```
sudo apt-get install libgtk-3-dev
bundle config set --local with gtk3 && bundle install
CLOGS_BACKEND=gtk3 ruby hacketyhack.rb
```

What it costs is portability of a different kind: libui, FXRuby, wxRuby and Qt
all ship or build on macOS and Windows, and a GTK3 application on macOS looks
like a GTK3 application. For Linux it is the cheapest fix available for
libui's bitmap problem; as the single backend for a cross-platform Shoes it is
the wrong shape.

**NAppGUI** is not packaged by any distribution and has no Ruby binding, so it
costs both of the things the others cost — a source build *and* a shim
this project owns:

```
sudo apt-get install libgtk-3-dev libcurl4-openssl-dev cmake
git clone --depth 1 https://github.com/frang75/nappgui_src
cmake -S nappgui_src -B nappgui_src/build -DCMAKE_BUILD_TYPE=Release
cmake --build nappgui_src/build --parallel
NAPPGUI_SRC=$PWD/nappgui_src clogs/ext/nappgui/build.sh
CLOGS_BACKEND=nappgui ruby hacketyhack.rb
```

The build takes about two minutes and produces ten static archives totalling
3 MB — genuinely small, which is the library's whole pitch, and it is a real
one: NAppGUI is the only dependency here that could plausibly be vendored into
a project. Against that, the shim in [`clogs/ext/nappgui/`](../ext/nappgui) is
about eight hundred lines of C++, and unlike the Qt shim part of it is
platform-specific — the key snooper is GTK, and Windows and macOS would each
need their own answer to the same problem.

So all five alternatives live behind opt-in, and libui stays the default.

## The seventh one is not a library

`CLOGS_BACKEND=wasm` puts the same Shoes document on an HTML canvas, with CRuby
itself compiled to WebAssembly and running in the page. Everything above --
what a toolkit exports, what it costs to link, whether it ships a binary --
stops applying. What is left is the same narrow boundary: a window, a drawing
surface, an event source.

It is the easiest of the seven to write, because a canvas 2D context is the
drawing model Clogs already had. Cairo's `move_to`, `curve_to`, `arc`, `clip`,
`fill_preserve` and matrix stack are `moveTo`, `bezierCurveTo`, `arc`, `clip`,
a path that survives its own fill, and `save`/`restore`. Nothing had to be
approximated, worked around or emulated -- unlike libui, which cannot blit;
FOX, which has no alpha; or NAppGUI, which cannot clip.

**The one thing that is genuinely different is who owns the loop.** Every other
backend blocks inside a native event loop and calls Ruby back. wasm runs on the
browser's only thread, so a Ruby loop that does not return freezes the page it
is painting into. So the ownership inverts: Lacci is told the display library's
loop "returns" -- its own supported mode, the one Clogs already used for nested
windows -- `Shoes.app` hands control straight back, and the page's
`requestAnimationFrame` drives input, timers and frames from then on.

That has a pleasant consequence. The frame clock is a parameter, not the wall
clock, so a test can stop the page ticking and advance the app's own time by
hand: `advance(1000)` is one second of every animation, `every`, and sleeping
thread, identically on any machine. See [`web/README.md`](../../web/README.md).

**And the boundary is expensive.** A call from wasm into JS costs about ten
microseconds -- a thousand times a native function call -- and a frame of
Hackety Hack is hundreds to thousands of drawing operations. Drawing op by op
would spend more time crossing the boundary than the browser spends painting.
So this backend does not draw immediately: `Painter` appends to a flat array of
numbers, handed over once per frame and replayed by `web/host.js`. Input goes
the same way, batched into one call per frame. Two crossings a frame, not
thousands.

### What it costs

The same benchmark programs `rake compare` runs, loaded in the browser, timing
the same thing -- `Clogs::App#on_draw`, the document paint:

| page | libui | fox | qt | gtk3 | nappgui | wasm |
|---|---|---|---|---|---|---|
| no image (control) | 0.98 ms | **0.34 ms** | 0.69 ms | 0.67 ms | 0.62 ms | 0.30 ms |
| 16x16 icon | 1.40 ms | 0.22 ms | 0.49 ms | 0.45 ms | 0.39 ms | 0.30 ms |
| 500x616 art | 8.77 ms | **0.20 ms** | 0.73 ms | 1.10 ms | 1.17 ms | 0.30 ms |
| 256x256 art with alpha | 18.75 ms | **0.19 ms** | 0.59 ms | 0.54 ms | 0.57 ms | 0.30 ms |
| 40 styled paragraphs | 50.87 ms | **9.11 ms** | 14.24 ms | 34.90 ms | 16.80 ms | 22.90 ms |

Read that column carefully, because it is measuring something slightly
different from the others even though the code is identical. Emitting a
`drawImage` op is five numbers whatever the picture is, and the browser's own
blit happens afterwards, during replay -- which is why the image rows are flat,
and why the whole frame including serialising and replaying still lands at
0.3-0.4 ms. Text is the honest row: 5,787 ops for forty styled paragraphs, all
of them built in Ruby, on a Ruby that is several times slower than the native
one. It still beats libui, wx and gtk3, because what it is not doing is
crossing a boundary per operation.

Hackety Hack's own splash screen is 774 ops, 4.7 ms to build and 6.2 ms to put
on the canvas.

### What it gives up

- **Sockets.** There are none in a browser. `net/http` is shimmed to raise the
  `SocketError` an offline machine raises.
- **File pickers.** `ask_open_file` and friends return nil: a page cannot wait
  for a picker synchronously, and Shoes' API is synchronous. `alert`, `confirm`
  and `ask` are fine -- `window.alert` and friends really do block.
- **Preemptive threads.** wasm CRuby has none, so `Thread.new` becomes a Fiber
  scheduled between frames, with `sleep` and `Queue#pop` yielding to the
  scheduler. Shoes programs use threads to keep a window alive while something
  runs, which this does; they do not use them for parallelism, which it cannot.
- **Reading the system clipboard.** `navigator.clipboard.readText` is
  asynchronous and permission-gated. Copying and pasting within a Shoes program
  works; pasting from another application does not.
- **C extensions.** Hackety Hack wants sqlite3 and nokogiri. sqlite3 is
  replaced by a key/value shim over localStorage, which is all HH::Database
  uses it for; nokogiri is replaced by a stub, because everything reaching for
  it is one of the hackety.org features that has had no server since 2013.

## Verdict

**The headline is what gtk3 proves.** It and libui are the same Cairo and the
same Pango -- on Linux libui is a thin C wrapper over exactly this -- and gtk3
paints Hackety Hack's splash thirty-five times faster, draws the Cheat Sheet at
full resolution instead of every second pixel, and renders `del()` with a line
through it. None of that is a difference between libraries. All of it is the
wrapper. Anyone reading `libui_shoes_coverage.md` as a list of things Shoes
cannot have on this stack should read it instead as a list of things libui does
not expose.

**Qt draws the best frame.** It matches libui's rendering exactly, is thirty to
thirty times cheaper on artwork, three and a half times faster than libui or wx on text, and
one of the four backends that passes Clogs' whole suite without skips. If the
question is purely "which of these draws Hackety Hack best", the answer is Qt.

**wx is the one to actually adopt for Hackety Hack.** It draws the same frame
as Qt to within a hair, and it comes with a binding somebody else maintains.
`wxTextCtrl` and Scintilla are both there for the editor tab the README calls
"not usable yet", and wx can position a native control at an arbitrary point —
precisely what `libui_shoes_coverage.md` says libui structurally cannot do.
Choosing wx over Qt is choosing a maintained dependency over five hundred lines
of C++ that this project would then own.

**For Clogs as a gem, keep libui as the default.** A Shoes implementation
someone can `gem install` is worth more than a faster one they cannot build,
and libui's one real weakness — the cost of a bitmap — is a problem for
artwork-heavy programs specifically rather than for Shoes programs generally.

**FOX is the interesting outlier.** It is the fastest by a distance and the
cheapest of the alternatives to install, and it pays for that with
antialiasing and alpha. For a Shoes program made of flat art and text that is
an excellent trade; for one made of photographs and translucency it is the
wrong one.

**For Linux specifically, gtk3 is the cheapest win available.** It needs no new
runtime dependency -- libui already pulls GTK in -- and it removes every
drawing weakness in this document at once. If Clogs only had to run on Linux,
this would be the recommendation outright.

**NAppGUI draws better than its size suggests and types worse.** It keeps pace
with Qt, wx and gtk3 across the benchmark while giving up none of the fidelity
FOX trades away for its speed, its whole SDK is a two-minute build and 3 MB of
static archives, and its `TextView` is the editor widget Hackety Hack needs.
What it
is not is a library you can put a text editor on: its key event carries a
virtual key from a fixed table with no room for half a US keyboard and no
character anywhere in it, and getting real characters out of it meant a
deprecated GTK key snooper that would have to be written again for Windows and
macOS. Everything else it lacks -- clipping, a path object, the even-odd fill
rule -- Clogs works around in Ruby for a few lines and a bitmap. The keyboard
is the one that is not worked around, only routed past.

Worth doing next, in order:

1. **Cache text layouts.** 50 ms a frame for forty paragraphs is a missing
   cache in Clogs, not a limitation of libui, wx or gtk3, and fixing it helps
   all three.
2. **Use native controls for `edit_line` and `edit_box` on wx**, positioned by
   the Shoes layout engine. That is what the editor tab needs, and wx is the
   backend that can provide it.
3. **Raise libui's run budget, or downscale properly.** Sampling every second
   pixel is why the Cheat Sheet is unreadable on the default backend, and a
   filtered downscale would cost the encoder nothing per frame.
4. **Report the wxRuby3 link-flag bug upstream**, so the patch above stops
   being necessary.
5. **Ask NAppGUI upstream for a character in `EvKey`.** Every platform it
   targets has one at the point where NAppGUI reads the virtual key, and
   without it the library cannot host a text editor on any keyboard layout it
   was not designed around.
