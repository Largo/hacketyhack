# Hackety Hack

Hackety Hack is a programming starter kit: an editor with helpful coding tools,
written by _why the lucky stiff's community on top of
[Shoes](https://github.com/shoes/shoes-deprecated).

It stopped working because Shoes stopped working. The old README pointed at
Shoes 4, a JRuby rewrite that never got far enough to run Hackety Hack.

This branch takes a different route: **Clogs**, a Shoes implementation built on
[libui](https://github.com/libui-ng/libui-ng) that runs on plain CRuby.

## Clogs

[`clogs/`](clogs) is a standalone gem — Shoes, worn over libui. No browser
engine, no JVM, one small native dependency that ships prebuilt for Linux,
macOS and Windows.

```ruby
require "clogs"

Shoes.app(title: "Hello", width: 400, height: 200) do
  para "Hello, ", strong("Shoes"), "!", size: :title
  button("Push me") { @note.replace "Aha! Clicked." }
  @note = para "Nothing pushed so far"
end
```

It takes the Shoes DSL from [Lacci](https://github.com/scarpe-team/scarpe) (the
display-independent half of Scarpe) and implements the display side itself:
layout, text, painting, widgets and input. See
[`clogs/README.md`](clogs/README.md) and the tested feature matrix in
[`clogs/docs/libui_shoes_coverage.md`](clogs/docs/libui_shoes_coverage.md).

## Where the port stands

**The IDE runs.** `ruby hacketyhack.rb` opens Hackety Hack: the splash
animation, the side tabs, the Home tab and its artwork all render on Clogs.
`rake boot` proves it headlessly and CI runs that on every push.

```
bundle install
ruby hacketyhack.rb    # the IDE
rake samples           # the bundled Shoes programs, headless
rake boot              # IDE smoke test
rake compare           # time a frame on every Clogs backend
```

Clogs has five interchangeable display backends: libui (the default), FOX via
FXRuby, wxWidgets via wxRuby3, Qt through a small C shim this repo carries
(Ruby has no maintained Qt binding), and GTK3 via ruby-gnome. All five boot the
IDE and pass the same 11 of the 12 samples. They differ in what a frame costs,
mostly because libui cannot blit a bitmap and has to paint pictures as
rectangles:

| median frame | libui | fox | wx | qt | gtk3 |
|---|---|---|---|---|---|
| the splash hand, 256x256 with alpha | 18.56 ms | 0.12 ms | 0.39 ms | 0.45 ms | 0.44 ms |
| 40 styled paragraphs | 71.92 ms | 9.64 ms | 66.86 ms | 15.50 ms | 45.99 ms |

The libui and gtk3 columns are the same Cairo and the same Pango -- on Linux
libui is a thin C wrapper over exactly them -- so that 42x is the wrapper, not
the stack. Qt draws the best frame overall, wx is the most portable of the
alternatives, FOX is faster than any of them but loses antialiasing and alpha,
and libui stays the default because it is the only one that installs without a
compiler. `rake compare` reproduces the table, and the trade-offs are in
[`clogs/docs/backends.md`](clogs/docs/backends.md).

Eleven of the twelve Shoes programs in `samples/` run unmodified on every
backend — `Clock`, `Scribble`, `Pong`, `Duel`, `Follow`, `Arcs`, `Fractal`,
`Funnies`, `Animated Flowers` and both `Turtle` programs — exercising
animation, `clear`/redraw, mouse input, art drawables, turtle widgets and
styled text. `rake samples` names the twelfth rather than hiding it:
`Guessing Game` is a bare `ask` loop with nobody headless to answer it.

Getting here meant fixing real divergences between Shoes 3 and Lacci, all in
`lib/compat/shoes3.rb`:

- **Slot-block scoping.** Lacci `instance_eval`s slot blocks into the app and
  documents this as a known incompatibility. Hackety Hack's tab classes set
  `@content` inside `slot.append { ... }` and read it back later, so those
  ivars were landing on the app. Shoes Classic semantics are restored: the
  block keeps its own `self`, and Shoes DSL calls forward to the app.
- **Widget blocks.** Lacci hands a `Shoes::Widget`'s block to the widget's
  initializer *and* then runs it again as the widget's slot body (its source
  marks this "# Do Widgets do this?"). Hackety Hack's widgets take that block
  as a click handler, so it fired at creation time.
- Trailing-hash arguments, `window`, `dialog`, chained `hover`/`leave`/`click`,
  `move`/`displace`, `finish`, class-level `style`, `Shoes::COLORS`,
  `Shoes::Mask`, positional `shape`/`oval` origins, negative arc angles, and
  `para.cursor`.

Hpricot, which has not built since 2010, is replaced by a Nokogiri shim, and
the dead hackety.org version check no longer crashes startup.

**Still rough.** The editor tab is not usable yet and the online features point
at a server that no longer exists. Large images are expensive to draw on the
default backend — see the note on libui and bitmaps in the coverage matrix, and
`CLOGS_BACKEND=wx` for the version of Clogs that does not have that problem.

## Development

```
bundle install
rake samples                                  # the Shoes samples, headless
cd clogs && rake test                         # Clogs' own suite
ruby -Iclogs/lib clogs/examples/kitchen_sink.rb

# The alternative backends are optional; each needs its toolkit's headers.
sudo apt-get install libfox-1.6-dev libxrandr-dev            # for fox
sudo apt-get install libwxgtk3.2-dev libwxgtk-webview3.2-dev \
                     libwxgtk-media3.2-dev swig doxygen      # for wx
bundle config set --local with "fox wx" && bundle install
CLOGS_BACKEND=wx rake samples

sudo apt-get install qt6-base-dev                            # for qt
rake qt:build                                                # builds the shim
CLOGS_BACKEND=qt rake samples

sudo apt-get install libgtk-3-dev                            # for gtk3
bundle config set --local with gtk3 && bundle install
CLOGS_BACKEND=gtk3 rake samples

rake compare                                                 # all five, timed
SHOT_DIR=tmp/shots CLOGS_BACKEND=qt ruby -Iclogs/lib -I. tools/screenshots.rb
```

On a headless machine, prefix GUI commands with `xvfb-run -a`.

## Licence

See [LICENSE](LICENSE). Clogs is MIT.
