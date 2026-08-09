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

**Working.** Clogs runs Shoes programs. Six of the twelve Shoes programs that
Hackety Hack ships in `samples/` run unmodified:

```
bundle install
rake samples          # runs each sample headlessly and reports pass/fail
```

`Clock`, `Scribble`, `Pong`, `Duel`, `Follow` and `Arcs` all work, exercising
animation, `clear`/redraw, mouse input, art drawables and styled text. The other
six need Shoes 3 features that are not implemented — off-screen `image`
canvases, `download`, and Hackety Hack's own turtle widgets. `rake samples`
lists them explicitly rather than hiding them.

Also done as part of this work:

- Hpricot, which has not built since 2010, is replaced by a Nokogiri-backed
  shim (`lib/compat/hpricot.rb`).
- A Shoes 3 compatibility layer (`lib/compat/shoes3.rb`) bridges the gap between
  Shoes 3 and Lacci: trailing-hash arguments, `window`, `dialog`, chained
  `hover`/`leave`/`click`, `move`/`displace`, `finish`, class-level `style`,
  four-argument `oval`, negative arc angles.
- The dead hackety.org version check no longer crashes startup.

**Not working yet: the IDE itself.** `app/ui/mainwindow.rb` now gets a long way
— the window opens, the side tabs and content slots are built — but it stops at
a structural difference. Shoes 3 ran a slot block with `self` still set to the
object that wrote it, so Hackety Hack's tab classes could set `@content` inside
`slot.append do ... end` and read it back later. Lacci `instance_eval`s slot
blocks into the app, so those instance variables land on the wrong object.

Fixing this properly means either teaching Lacci about slot-block owners
(the better fix, and useful to Scarpe as well) or restructuring Hackety Hack's
tab classes to stop relying on it. Neither is a shim.

## Development

```
bundle install
rake samples                                  # the Shoes samples, headless
cd clogs && rake test                         # Clogs' own suite
ruby -Iclogs/lib clogs/examples/kitchen_sink.rb
```

On a headless machine, prefix GUI commands with `xvfb-run -a`.

## Licence

See [LICENSE](LICENSE). Clogs is MIT.
