# Which display library should Shoes sit on?

Clogs paints the whole Shoes document itself and uses its display library for
three things only: a window, a drawing surface and an event source. That
boundary is narrow enough to write more than once, so it has been — against
libui, FOX, wxWidgets, Qt and GTK3 — and all five run the same programs, so
they can be compared by measurement rather than by argument.

```
CLOGS_BACKEND=libui ruby hacketyhack.rb    # the default
CLOGS_BACKEND=fox   ruby hacketyhack.rb
CLOGS_BACKEND=wx    ruby hacketyhack.rb
CLOGS_BACKEND=qt    ruby hacketyhack.rb    # needs clogs/ext/qt/build.sh first
CLOGS_BACKEND=gtk3  ruby hacketyhack.rb
rake compare                               # the benchmark table below
```

**Short answer: libui's weaknesses are libui's, not its stack's — and the
cheapest way to fix them is gtk3.** On Linux libui *is* GTK3 and Cairo, one C
wrapper down. Reaching the same libraries directly makes the same picture
forty times cheaper to draw and stops it being downsampled, without changing a
pixel of what Shoes programs look like. Qt draws the best frame overall and wx
is the most portable of the alternatives; libui stays the default because it
is the only one that installs without a compiler.

## The measurement

`rake compare` paints a Shoes document repeatedly for five seconds with a 60fps
animation driving the repaints, and reports the median time to paint one whole
frame.

| page | libui | fox | wx | qt | gtk3 |
|---|---|---|---|---|---|
| no image (control) | 0.78 ms | **0.28 ms** | 1.28 ms | 0.53 ms | 0.50 ms |
| 16×16 icon | 1.30 ms | **0.15 ms** | 0.22 ms | 0.41 ms | 0.31 ms |
| 500×616 art (`hhhello.png`) | 8.42 ms | **0.13 ms** | 0.87 ms | 0.64 ms | 1.01 ms |
| 256×256 art with alpha (`splash-hand.png`) | 18.56 ms | **0.12 ms** | 0.39 ms | 0.45 ms | 0.44 ms |
| 40 styled paragraphs | 71.92 ms | **9.64 ms** | 66.86 ms | 15.50 ms | 45.99 ms |

**The libui and gtk3 columns are the interesting pair.** They are the same
Cairo and the same Pango: on Linux libui is a C wrapper over exactly this. Yet
gtk3 paints the alpha art forty-two times faster and the text page in two
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
Pango, and both are four times slower than Qt and half as fast as gtk3 at it. That 70 ms is a property
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

| Shoes needs | libui | FOX | wx | qt | gtk3 |
|---|---|---|---|---|---|
| Blit a bitmap | **no** — rectangles | yes | yes | yes | yes |
| Draws large art at full resolution | **no** — samples every 2nd pixel | yes | yes | yes | yes |
| Composite image alpha | yes | **no** — 1-bit shape mask | yes | yes | yes |
| Antialiasing | yes | **no** | yes | yes | yes |
| Transform stack (`rotate`, `scale`, `skew`) | yes | **no** — in Ruby, geometry only | yes | yes | yes |
| Rotate text and images | yes | **no** | yes | yes | yes |
| Gradients | yes | **no** — banded by hand | yes | yes | yes |
| Arbitrary path clipping | yes | region only | yes | yes | yes |
| Strikethrough, for `del()` | **no** | yes | yes | yes | yes |
| Image formats | **PNG only** (chunky_png) | 10 formats | 10 formats | 10+ formats | everything GdkPixbuf reads |
| Caret geometry, per-character positions | **no** | measures substrings | `get_partial_text_extents` | `QTextLayout` | `Pango#xy_to_index` |
| Second top-level window | **no** | yes | yes | yes | yes |
| Inner slot scrolling | **no** | `FXScrollArea` | `wxScrolledWindow` | `QScrollArea` | `Gtk::ScrolledWindow` |
| Native clipboard | **no** — shells out | yes | yes | yes | yes |
| Native `ask` dialog | **no** — hand-built | yes | yes | yes | hand-built (GTK has none) |
| A real text editor widget | **no** | `FXText`, Scintilla | `wxTextCtrl`, Scintilla | `QPlainTextEdit` | `Gtk::TextView` |
| Places a native control at (x, y) | **no** | yes | yes | yes | `Gtk::Fixed` |
| A Ruby binding that exists | yes | yes | yes | **no** — see below | yes |

`tools/bench_fidelity.rb` draws every disputed case on one page. Run it under
each backend and compare: libui, wx, qt and gtk3 are indistinguishable from one
another apart from libui's missing strikethrough, and FOX differs in exactly
the ways the table predicts — stepped edges on the star and the ovals, and two
overlapping translucent discs that do not blend.

`tools/screenshots.rb` does the same for the IDE itself, driving it through its
own `opentab` and photographing every pane on whichever backend is selected.

## What it took to make each one work

All five now do the same thing:

```
                              libui     fox      wx      qt    gtk3
rake samples                  11/12    11/12   11/12   11/12   11/12
rake boot                        ok       ok      ok      ok      ok
cd clogs && rake test         15/15    15/15   12/15   15/15   15/15
                                                + 3 skipped
```

The failing sample is `Guessing Game.rb` on all five, for the reason the
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

### gtk3

The least work of the five, which is the point: this is the library Clogs was
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

**GTK3** is the mildest of the four alternatives: ruby-gnome's binding is a C
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

So all four alternatives live behind opt-in, and libui stays the default.

## Verdict

**The headline is what gtk3 proves.** It and libui are the same Cairo and the
same Pango -- on Linux libui is a thin C wrapper over exactly this -- and gtk3
paints Hackety Hack's splash forty-two times faster, draws the Cheat Sheet at
full resolution instead of every second pixel, and renders `del()` with a line
through it. None of that is a difference between libraries. All of it is the
wrapper. Anyone reading `libui_shoes_coverage.md` as a list of things Shoes
cannot have on this stack should read it instead as a list of things libui does
not expose.

**Qt draws the best frame.** It matches libui's rendering exactly, is thirty to
forty times cheaper on artwork, four times faster than libui or wx on text, and
one of the three backends that passes Clogs' whole suite without skips. If the
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
cheapest of the three alternatives to install, and it pays for that with
antialiasing and alpha. For a Shoes program made of flat art and text that is
an excellent trade; for one made of photographs and translucency it is the
wrong one.

**For Linux specifically, gtk3 is the cheapest win available.** It needs no new
runtime dependency -- libui already pulls GTK in -- and it removes every
drawing weakness in this document at once. If Clogs only had to run on Linux,
this would be the recommendation outright.

Worth doing next, in order:

1. **Cache text layouts.** 70 ms a frame for forty paragraphs is a missing
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
