# Does Shoes fit better on FOX than on libui?

Short answer: **for Hackety Hack, yes — decisively on speed, at a real cost in
drawing quality.**

[`libui_shoes_coverage.md`](libui_shoes_coverage.md) records what libui can and
cannot do for Shoes. Its longest entry is the one about bitmaps: libui exports
no draw-image call, so Clogs decodes PNGs itself and paints them as run-length
encoded rectangles. Hackety Hack is a program made largely of artwork, so that
entry is not a footnote — it is the thing that decides whether the IDE feels
alive.

This document records what happened when the display half of Clogs was written
a second time, against [FXRuby](https://github.com/larskanis/fxruby) — Ruby
bindings for the [FOX toolkit](http://fox-toolkit.org/) — and the two were run
side by side. Everything here was measured by running code on FOX 1.6.57 /
FXRuby 1.6.50 / Ruby 3.3, not inferred from headers.

Select the backend with an environment variable:

```
CLOGS_BACKEND=fox ruby hacketyhack.rb
rake compare                            # the benchmark table below
```

## The measurement

`rake compare` paints a Shoes document repeatedly for five seconds with a
60fps animation driving the repaints, and reports the median time to paint one
whole frame.

| page | libui p50 | fox p50 | speedup |
|---|---|---|---|
| no image (control) | 0.71 ms | 0.23 ms | 3.1× |
| 16×16 icon | 1.13 ms | 0.14 ms | 8.1× |
| 500×616 art (`hhhello.png`) | 8.32 ms | 0.14 ms | 59× |
| 256×256 art with alpha (`splash-hand.png`) | 16.45 ms | 0.14 ms | 118× |
| 40 styled paragraphs | 58.41 ms | 8.50 ms | 6.9× |

Two things in that table matter more than the ratios.

**On libui a single image is the frame budget.** `splash-hand.png` is 256×256 —
the hand on Hackety Hack's own splash screen — and it costs 16 ms per frame,
which is one whole frame at 60fps spent on one small picture. The libui backend
is already about as clever as it can be here: it run-length encodes each row,
merges identical rows into taller rectangles, groups the result into one path
per colour and caches those paths across frames. That is what gets it down to
16 ms. The first frame, which builds the paths, costs 416 ms. On FOX the same
image is one `XPutImage` and does not vary with the picture at all: 0.14 ms
whether it is a 16×16 icon or a 500×616 illustration, and a 6 ms worst frame
instead of a 416 ms one.

**Text was the surprise.** libui hands text to Pango, which is a far better
text engine than anything reachable through FOX. But Clogs does its own word
layout, so what it actually asks for is the width of a short string and a draw
call for a run — and through libui each of those means building a
`uiAttributedString`, building a `uiDrawTextLayout` and freeing both. FOX
answers the same question with `FXFont#getTextWidth` on a cached font. A page
of 40 styled paragraphs goes from 58 ms per frame to 8.5 ms.

Cold start improves too: a run that loads and displays `hhcheat.png`
(488×1407) takes 1.50 s wall on libui and 0.54 s on FOX, because the encoding
pass that produces 20,798 rectangles is replaced by FOX's own PNG loader.

## What the FOX backend has to fake

FOX's `FXDC` is a thin layer over Xlib primitives. It has no transform stack
and no gradients, and — the important one — no alpha.

| Shoes needs | FOX has | What the backend does |
|---|---|---|
| `rotate`, `scale`, `skew` | nothing | Keeps a 3×2 affine matrix in Ruby and transforms every path point before handing it over. Geometry rotates correctly; **text and images cannot be rotated at all**, so a transform contributes only its translation to them |
| `background red..blue` | nothing | Clips to the shape and paints one 1px band per row. A 300-row gradient costs 0.20 ms, which is cheaper than almost anything else on the page |
| Bezier and arc paths | polygons only | Flattens curves to line segments (16 per bezier, one per ~11° of arc) |
| Arbitrary path clipping | rectangles and regions | `FXRegion` built from a polygon covers the gradient case; `clip_rect` under a rotation falls back to the device bounding box |
| `rgb(0, 0, 255, 0.45)` | nothing | Composites the colour against a fixed backdrop instead of against what is underneath it |
| Image alpha | a 1-bit shape mask on `FXIcon` | Cutouts keep their silhouette — the splash hand is a blob on black, not a white square — but a soft antialiased edge becomes a hard one |
| Antialiasing | none for shapes | Curves and diagonals are visibly jagged. Text is antialiased, because that goes through Xft |

Run `CLOGS_BACKEND=fox ruby -Iclogs/lib -I. tools/bench_fidelity.rb` against the
same file on libui to see all of these on one page. The differences that show
up are: FOX's ovals and stars have stepped edges; two overlapping translucent
discs blend on libui and do not on FOX; everything else — gradients, rotation,
dashes, stroke widths, text styling — matches.

**Alpha is the one place where libui is simply better and cannot be matched.**
Cairo composites; Xlib does not. If a Shoes program layers translucent art, the
libui backend is the one that renders it correctly.

## What FOX gives that libui does not

Several entries in libui's "what it does not give us" table are simply absent
on FOX:

| libui gap | On FOX |
|---|---|
| Only PNG can be decoded (chunky_png), everything else needs ImageMagick installed | FOX decodes PNG, JPEG, GIF, BMP, ICO, TIFF, PPM, PCX, TGA and XPM itself. `static/matz.jpg` loads; on libui it does not |
| No strikethrough attribute, so `del()` renders as plain text | The backend draws its own runs, so it draws the line. This is now wired through `Paragraph::TextStyle`, and `del()` is struck through on FOX |
| Shifted keys reported unshifted, needing a US-layout table in Clogs | `FXEvent#text` is what the keyboard layout actually produced, so no table and no layout assumption |
| No second top-level window | `FXTopWindow` is ordinary; multiple windows are free |
| No inner slot scrolling | `FXScrollArea` / `FXScrollWindow` exist |
| Clipboard shells out to `xclip` / `pbpaste` / `clip` | Native clipboard API (not yet used by this backend — the shell-out is shared and still in place) |
| No text editor widget, so the editor tab is drawn by hand | `FXText` is a full editor widget, and FXRuby ships Scintilla — which is what the still-unusable editor tab actually wants |
| Dialogs: `ask` needs a hand-built window on a nested event loop | `FXInputDialog`, `FXMessageBox` and `FXFileDialog` are native. The FOX `Dialogs` file is a third the size of the libui one |

FOX also has a real absolute-positioning container, which means the structural
objection in `libui_shoes_coverage.md` — "libui has no container that places a
native control at an arbitrary (x, y)" — does not apply to it. This backend
does **not** exploit that: it paints Clogs' own widgets exactly as the libui
backend does, so that the two can be compared like for like. Using real FOX
controls positioned by the Shoes layout engine is the obvious next experiment,
and it is the thing that would give `edit_line` and `edit_box` the input-method
support, accessibility and platform text shortcuts they currently lack.

## Does it actually run?

Everything the libui backend passes, the FOX backend passes.

```
                              libui     fox
rake samples                  11/12    11/12
rake boot                        ok       ok
cd clogs && rake test         15/15    15/15
```

The one failing sample is `Guessing Game.rb` on both, for the reason the
Rakefile already documents: it calls `ask` in an unattended loop and headless
CI has nobody to answer it.

Getting there needed two fixes that are worth naming, because both are hazards
the libui backend documents in its own terms:

- **Tearing down a window from inside a draw handler.** Fractal's turtle
  finishes drawing and quits, so by the time the document has finished
  painting there is no canvas left to blit onto. Constructing an `FXDCWindow`
  on a destroyed drawable aborts the process; freeing the back buffer while a
  device context is still open on it produces `BadDrawable` storms. The canvas
  drops the frame in the first case and defers the free in the second.
- **Paragraph width included trailing whitespace.** `Paragraph` already
  ignores a token's trailing space when deciding whether to wrap, but then
  measured to the pen position rather than to the last glyph, so a wrapped
  paragraph reported itself wider than the width it was asked to wrap at — by
  however wide a space happens to be in the font. libui's Sans and FOX's
  Helvetica differ there, which is what exposed it. Fixed in `Paragraph`, for
  both backends.

## The cost of the dependency

This is the part that argues the other way.

The libui gem ships prebuilt binaries for Linux, macOS and Windows: `bundle
install` and it works, which for a program meant to be handed to a beginner is
most of the point.

FXRuby is a C++ extension. There are prebuilt Windows gems, but on Linux and
macOS it compiles against FOX 1.6's headers, and it needs them present:
`libfox-1.6-dev` on Debian and Ubuntu (plus `libxrandr-dev`, which the build
does not name and fails at the link step without), `fox` on Homebrew. FOX 1.6
itself is a stable-to-the-point-of-dormant toolkit whose last release was 2023
and whose look is unmistakably that of a 2005 X11 application.

So it is not installed by default. The `Gemfile` puts it in an optional group:

```
bundle config set --local with fox
bundle install
```

## Verdict

For a Shoes implementation in the abstract, libui is the better base: Cairo
compositing, antialiasing, real transforms, a genuine text engine, and a
dependency that installs itself.

For **Hackety Hack specifically**, FOX wins, because the two things Hackety
Hack is made of are the two things libui is worst at. It is an IDE built out of
artwork and text — the tabs, the Home pane, the splash — and on libui a single
piece of that artwork eats a whole frame while a page of text eats three. The
IDE is not merely faster on FOX, it is the difference between an animation that
runs and one that stutters. And the editor tab, the piece the README calls "not
usable yet", is a solved problem on a toolkit that ships both `FXText` and
Scintilla.

The honest recommendation is neither "switch" nor "don't": keep both. The
backend is selected by one environment variable, the two are the same 11/12 on
the samples, and the code they share is everything that matters — the layout
engine, the drawable tree, the Shoes 3 compatibility work. What is worth doing
next, in order:

1. Use real FOX controls for `edit_line` and `edit_box`, positioned by the
   Shoes layout engine. This is the thing libui structurally cannot do, and it
   is what the editor tab needs.
2. Composite image alpha against the slot's actual background rather than a
   fixed backdrop, which would close most of the remaining fidelity gap for
   real Shoes programs.
3. Reduce the libui backend's text cost by caching layouts, which is worth
   doing regardless of which backend wins — 58 ms a frame for forty
   paragraphs is not a libui limitation, it is a missing cache.
