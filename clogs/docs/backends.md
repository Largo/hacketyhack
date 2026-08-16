# Which display library should Shoes sit on?

Clogs paints the whole Shoes document itself and uses its display library for
three things only: a window, a drawing surface and an event source. That
boundary is narrow enough to write more than once, so it has been — against
libui, against FOX and against wxWidgets — and all three run the same programs,
so they can be compared by measurement rather than by argument.

```
CLOGS_BACKEND=libui ruby hacketyhack.rb    # the default
CLOGS_BACKEND=fox   ruby hacketyhack.rb
CLOGS_BACKEND=wx    ruby hacketyhack.rb
rake compare                               # the benchmark table below
```

**Short answer: wx is the best backend for Hackety Hack, and libui is still the
right default for Clogs as a gem.** wx draws exactly what libui draws — it is
the same Cairo underneath — while putting Hackety Hack's artwork on screen ten
to forty-five times more cheaply. What it costs is the dependency: libui and
FXRuby install in seconds, wxRuby3 needs three distribution packages, a
multi-minute C++ build, and a patch before it will build against a
distribution's own wxWidgets at all.

## The measurement

`rake compare` paints a Shoes document repeatedly for five seconds with a 60fps
animation driving the repaints, and reports the median time to paint one whole
frame.

| page | libui | fox | wx |
|---|---|---|---|
| no image (control) | 0.83 ms | **0.21 ms** | 1.21 ms |
| 16×16 icon | 1.27 ms | **0.14 ms** | 0.24 ms |
| 500×616 art (`hhhello.png`) | 8.35 ms | **0.16 ms** | 0.86 ms |
| 256×256 art with alpha (`splash-hand.png`) | 17.96 ms | **0.17 ms** | 0.40 ms |
| 40 styled paragraphs | 67.72 ms | **9.60 ms** | 67.72 ms |

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
Pango. That 68 ms is a property of neither: Clogs rebuilds a text layout per
styled run per frame, and caching those is the single biggest improvement
available to either. FOX is quicker here only because it asks a font for a
string width instead of building a layout object at all.

Cold start with the 488×1407 `hhcheat.png`: libui 1.50 s, FOX 0.54 s.

## What each one gives up

| Shoes needs | libui | FOX | wx |
|---|---|---|---|
| Blit a bitmap | **no** — rectangles | yes | yes |
| Composite image alpha | yes | **no** — 1-bit shape mask | yes |
| Antialiasing | yes | **no** | yes |
| Transform stack (`rotate`, `scale`, `skew`) | yes | **no** — in Ruby, geometry only | yes |
| Rotate text and images | yes | **no** | yes |
| Gradients | yes | **no** — banded by hand | yes |
| Arbitrary path clipping | yes | region only | yes |
| Strikethrough, for `del()` | **no** | yes | yes |
| Image formats | **PNG only** (chunky_png) | 10 formats | 10 formats |
| Caret geometry, per-character positions | **no** | measures substrings | `get_partial_text_extents` |
| Second top-level window | **no** | yes | yes |
| Inner slot scrolling | **no** | `FXScrollArea` | `wxScrolledWindow` |
| Native clipboard | **no** — shells out | yes | yes |
| Native `ask` dialog | **no** — hand-built | yes | yes |
| A real text editor widget | **no** | `FXText`, Scintilla | `wxTextCtrl`, Scintilla |
| Places a native control at (x, y) | **no** | yes | yes |

`tools/bench_fidelity.rb` draws every disputed case on one page. Run it under
each backend and compare: wx's output and libui's are indistinguishable apart
from the strikethrough, and FOX's differs in exactly the ways the table
predicts — stepped edges on the star and the ovals, and two overlapping
translucent discs that do not blend.

## What it took to make each one work

All three now do the same thing:

```
                              libui     fox      wx
rake samples                  11/12    11/12   11/12
rake boot                        ok       ok      ok
cd clogs && rake test         15/15    15/15   12/15 + 3 skipped
```

The failing sample is `Guessing Game.rb` on all three, for the reason the
Rakefile already documents: it calls `ask` in an unattended loop and headless
CI has nobody to answer it.

The three skipped tests are wx's alone, and the skip is honest: they measure
text, and wx cannot build a font until its application object exists, which
only happens inside its main loop. libui and FOX need only a display.

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

**wxRuby3** is the heaviest by a wide margin:

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

So both alternatives live in optional bundler groups, and libui stays the
default.

## Verdict

**For Hackety Hack, use wx.** It draws exactly what libui draws — same Cairo,
same antialiasing, same alpha, same text — and puts the artwork the IDE is made
of on screen ten to forty-five times more cheaply. It is also the only backend
where the editor tab, the piece the README calls "not usable yet", has an
obvious answer: `wxTextCtrl` and Scintilla are both there, and wx can position
a native control at an arbitrary point, which is precisely what
`libui_shoes_coverage.md` says libui structurally cannot do.

**For Clogs as a gem, keep libui as the default.** A Shoes implementation
someone can `gem install` is worth more than a faster one they cannot build,
and libui's one real weakness — the cost of a bitmap — is a problem for
artwork-heavy programs specifically rather than for Shoes programs generally.

**FOX is the interesting third answer.** It is the fastest by a distance and
the cheapest of the two alternatives to install, and it pays for that with
antialiasing and alpha. For a Shoes program made of flat art and text that is
an excellent trade; for one made of photographs and translucency it is the
wrong one.

Worth doing next, in order:

1. **Cache text layouts.** 68 ms a frame for forty paragraphs is a missing
   cache in Clogs, not a limitation of libui or wx, and fixing it helps both.
2. **Use native controls for `edit_line` and `edit_box` on wx**, positioned by
   the Shoes layout engine. That is what the editor tab needs, and wx is the
   backend that can provide it.
3. **Report the wxRuby3 link-flag bug upstream**, so the patch above stops
   being necessary.
