# Hackety Hack on modern Ruby

This release moves Hackety Hack off Shoes 3 (and off the JRuby-based Shoes 4
that the old README pointed at) and onto **Clogs**, a new Shoes implementation
that runs on plain CRuby with [libui](https://github.com/libui-ng/libui-ng).

No browser engine. No JVM. One small native dependency that ships prebuilt for
Linux, macOS and Windows.

## What's in the box

- **`clogs-0.1.0.gem`** — Shoes, worn over libui. Install it and `Shoes.app`
  works on CRuby 3.2+.
- **`hacketyhack-*.zip` / `.tar.gz`** — the Hackety Hack tree, including Clogs
  and the Shoes 3 compatibility layer.

## Hackety Hack runs again

`ruby hacketyhack.rb` opens the IDE: the splash animation, the side tabs, the
Home tab and its artwork all render. CI boots it headlessly on every push.

Six of the twelve bundled Shoes programs in `samples/` run unmodified —
`Clock`, `Scribble`, `Pong`, `Duel`, `Follow` and `Arcs` — covering animation,
`clear`/redraw, mouse input, art drawables and styled text. `rake samples`
reports the rest rather than hiding them.

Getting there meant fixing genuine divergences between Shoes 3 and Lacci, most
notably slot-block scoping (Lacci `instance_eval`s slot blocks into the app, so
instance variables set inside `slot.append` landed on the wrong object) and
widget blocks being run twice. Hpricot, unbuildable since 2010, is replaced by
a Nokogiri shim.

**Still rough:** the editor tab is not usable yet, the online features point at
a server that no longer exists, and large bitmaps are expensive to draw.

## Clogs

Working: layout, styled and wrapped text, links located correctly mid-paragraph,
art drawables, gradients, images, widgets, mouse and keyboard input, animation
and dialogs. Not working: video, sound, blur, and multiple windows.

`clogs/docs/libui_shoes_coverage.md` has a tested, feature-by-feature matrix —
including the finding that the shipped libui exports no `uiDrawImage`, and a
verified escape hatch for positioning native controls at arbitrary coordinates
through `uiControlHandle`.

## Running it

```
gem install clogs
ruby -e 'require "clogs"; Shoes.app { para "Hello from Clogs" }'
```

Linux also needs GTK3 (`apt install libgtk-3-0`); macOS and Windows need
nothing extra.
