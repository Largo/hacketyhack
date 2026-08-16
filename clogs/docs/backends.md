# Which display library should Shoes sit on?

Clogs paints the whole Shoes document itself and uses its display library for
three things only: a window, a drawing surface and an event source. That
boundary is narrow enough to write more than once, so it has been — against
libui, against FOX, against wxWidgets and against Qt — and all four run the
same programs, so they can be compared by measurement rather than by argument.

```
CLOGS_BACKEND=libui ruby hacketyhack.rb    # the default
CLOGS_BACKEND=fox   ruby hacketyhack.rb
CLOGS_BACKEND=wx    ruby hacketyhack.rb
CLOGS_BACKEND=qt    ruby hacketyhack.rb    # needs clogs/ext/qt/build.sh first
rake compare                               # the benchmark table below
```

**Short answer: Qt draws the best frame, and libui is still the right default
for Clogs as a gem.** Qt matches libui's rendering exactly, puts Hackety Hack's
artwork on screen thirty to forty times more cheaply, and is four times faster
than either libui or wx at text. Its catch is not fidelity or speed but
supply: Ruby has no maintained Qt binding at all, so this backend carries its
own C shim.

## The measurement

`rake compare` paints a Shoes document repeatedly for five seconds with a 60fps
animation driving the repaints, and reports the median time to paint one whole
frame.

| page | libui | fox | wx | qt |
|---|---|---|---|---|
| no image (control) | 0.69 ms | **0.21 ms** | 1.22 ms | 0.49 ms |
| 16×16 icon | 1.46 ms | **0.15 ms** | 0.22 ms | 0.35 ms |
| 500×616 art (`hhhello.png`) | 9.00 ms | **0.12 ms** | 0.89 ms | 0.70 ms |
| 256×256 art with alpha (`splash-hand.png`) | 19.50 ms | **0.13 ms** | 0.41 ms | 0.51 ms |
| 40 styled paragraphs | 72.02 ms | **9.07 ms** | 69.52 ms | 15.46 ms |

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
compositing, which is why it is five times quicker than wx at getting a bitmap
onto the screen and also why it cannot honour that bitmap's alpha. The speed
and the fidelity loss are the same fact.

**wx and libui draw text at exactly the same speed**, because it is the same
Pango, and both are four times slower than Qt at it. That 70 ms is a property
of neither library: Clogs rebuilds a text layout object per styled run per
frame, and caching those is the single biggest improvement available to either.
FOX and Qt are quicker because neither builds a layout object at all — they ask
for a string's width and draw it.

Cold start with the 488×1407 `hhcheat.png`: libui 1.50 s, FOX 0.54 s.

**libui also draws large art at reduced resolution**, which the frame timings
do not show. Its encoder gives up at 40,000 rectangles and then samples every
second pixel: `hhcheat.png` needs 66,455 runs at full resolution and
`hhhello.png` 100,183, so both are downsampled. Hackety Hack's Cheat Sheet is
legible on the other three backends and smeared on libui.

## What each one gives up

| Shoes needs | libui | FOX | wx | qt |
|---|---|---|---|---|
| Blit a bitmap | **no** — rectangles | yes | yes | yes |
| Draws large art at full resolution | **no** — samples every 2nd pixel | yes | yes | yes |
| Composite image alpha | yes | **no** — 1-bit shape mask | yes | yes |
| Antialiasing | yes | **no** | yes | yes |
| Transform stack (`rotate`, `scale`, `skew`) | yes | **no** — in Ruby, geometry only | yes | yes |
| Rotate text and images | yes | **no** | yes | yes |
| Gradients | yes | **no** — banded by hand | yes | yes |
| Arbitrary path clipping | yes | region only | yes | yes |
| Strikethrough, for `del()` | **no** | yes | yes | yes |
| Image formats | **PNG only** (chunky_png) | 10 formats | 10 formats | 10+ formats |
| Caret geometry, per-character positions | **no** | measures substrings | `get_partial_text_extents` | `QTextLayout` |
| Second top-level window | **no** | yes | yes | yes |
| Inner slot scrolling | **no** | `FXScrollArea` | `wxScrolledWindow` | `QScrollArea` |
| Native clipboard | **no** — shells out | yes | yes | yes |
| Native `ask` dialog | **no** — hand-built | yes | yes | yes |
| A real text editor widget | **no** | `FXText`, Scintilla | `wxTextCtrl`, Scintilla | `QPlainTextEdit` |
| Places a native control at (x, y) | **no** | yes | yes | yes |
| A Ruby binding that exists | yes | yes | yes | **no** — see below |

`tools/bench_fidelity.rb` draws every disputed case on one page. Run it under
each backend and compare: libui, wx and qt are indistinguishable from one
another apart from libui's missing strikethrough, and FOX differs in exactly
the ways the table predicts — stepped edges on the star and the ovals, and two
overlapping translucent discs that do not blend.

`tools/screenshots.rb` does the same for the IDE itself, driving it through its
own `opentab` and photographing every pane on whichever backend is selected.

## What it took to make each one work

All four now do the same thing:

```
                              libui     fox      wx      qt
rake samples                  11/12    11/12   11/12   11/12
rake boot                        ok       ok      ok      ok
cd clogs && rake test         15/15    15/15   12/15   15/15
                                                + 3 skipped
```

The failing sample is `Guessing Game.rb` on all four, for the reason the
Rakefile already documents: it calls `ask` in an unattended loop and headless
CI has nobody to answer it.

The three skipped tests are wx's alone, and the skip is honest: they measure
text, and wx cannot build a font until its application object exists, which
only happens inside its main loop. The other three need only a display.

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

Qt itself gave the least trouble of the four; the awkwardness was all at the
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

Two shared bugs also fell out of writing the display half three times:

- **Paragraph reported a wrapped paragraph wider than the width it was asked to
  wrap at**, because it measured to the pen position rather than to the last
  glyph, counting the trailing space its own wrap decision already ignores. The
  three backends' fonts differ there, which is what exposed it.
- **The test helper booted the display through a libui-only call**, so every
  test needing a display skipped silently on any other backend.

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
*self-contained* of the three alternatives: one .cpp file and a two-line build,
against wxRuby3's SWIG-generated extension and its patch.

So all three alternatives live behind opt-in, and libui stays the default.

## Verdict

**Qt draws the best frame.** It matches libui's rendering exactly, is thirty to
forty times cheaper on artwork, four times faster than libui or wx on text, and
the only backend besides libui that passes Clogs' whole suite without skips. If
the question is purely "which of these draws Hackety Hack best", the answer is
Qt.

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
cheapest of the three alternatives to install, and it pays for that with
antialiasing and alpha. For a Shoes program made of flat art and text that is
an excellent trade; for one made of photographs and translucency it is the
wrong one.

Worth doing next, in order:

1. **Cache text layouts.** 68 ms a frame for forty paragraphs is a missing
   cache in Clogs, not a limitation of libui or wx, and fixing it helps both.
2. **Use native controls for `edit_line` and `edit_box` on wx**, positioned by
   the Shoes layout engine. That is what the editor tab needs, and wx is the
   backend that can provide it.
3. **Raise libui's run budget, or downscale properly.** Sampling every second
   pixel is why the Cheat Sheet is unreadable on the default backend, and a
   filtered downscale would cost the encoder nothing per frame.
4. **Report the wxRuby3 link-flag bug upstream**, so the patch above stops
   being necessary.
