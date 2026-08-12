# Clogs

**Shoes, worn over libui.**

Clogs runs [Shoes](https://github.com/shoes/shoes-deprecated) programs on plain
CRuby. No browser engine, no JVM — just [libui](https://github.com/libui-ng/libui-ng),
a small native widget library that ships as a prebuilt shared object for Linux,
macOS and Windows.

```ruby
require "clogs"

Shoes.app(title: "Hello", width: 400, height: 200) do
  para "Hello, ", strong("Shoes"), "!", size: :title
  button("Push me") { @note.replace "Aha! Clicked." }
  @note = para "Nothing pushed so far"
end
```

```
gem install clogs
clogs hello.rb
```

`clogs` is a small stand-in for Shoes 3's own `shoes` command: it requires
`clogs` for you and runs the program you name. `ruby hello.rb` (with a
top-level `require "clogs"` as above) works exactly the same way.

## How it fits together

The Shoes API itself comes from [Lacci](https://github.com/scarpe-team/scarpe),
the display-independent half of Scarpe. Lacci owns the DSL and the drawable
tree; Clogs is a Lacci *display service* and owns the pixels.

```
your Shoes program
        |
      Lacci          the Shoes DSL, drawable tree, events
        |
      Clogs          layout, painting, widgets, input
        |
      libui          one native window, one canvas
```

You can also select it explicitly, which is useful when the same program should
run under Scarpe's webview backend too:

```
SCARPE_DISPLAY_SERVICE=clogs ruby my_app.rb
```

## What it looks like

Clogs paints the entire Shoes document into a single libui canvas, including the
widgets. That is not a shortcut: libui has no way to place a native control at an
arbitrary position, and Shoes needs exactly that. The trade-offs — and a tested
feature-by-feature matrix — are in
[docs/libui_shoes_coverage.md](docs/libui_shoes_coverage.md).

The short version: layout, text, links, art drawables, images, widgets, events,
animation and dialogs all work. Video, sound, blur and multiple windows do not.

## Development

```
cd clogs
bundle install
rake test                                  # unit tests plus real windowed runs
ruby -Ilib examples/kitchen_sink.rb        # see it
```

The tests open real windows, so on a headless machine run them under Xvfb:

```
xvfb-run -a rake test
```

Two environment variables make Shoes apps scriptable, which is how Clogs tests
itself and how you can screenshot an app from CI:

```
CLOGS_EXIT_AFTER_MS=800 CLOGS_SCREENSHOT=shot.png ruby -Ilib examples/kitchen_sink.rb
```

## Licence

MIT.
