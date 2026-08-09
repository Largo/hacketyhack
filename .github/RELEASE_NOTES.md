# Hackety Hack on modern Ruby

This release moves Hackety Hack off Shoes 3 (and off the JRuby-based Shoes 4
that the old README pointed at) and onto **Clogs**, a new Shoes implementation
that runs on plain CRuby with [libui](https://github.com/libui-ng/libui-ng).

## What's in the box

- **`clogs-*.gem`** — Shoes on libui. Install it and `Shoes.app` works on
  CRuby 3.2+, with no browser engine and no JVM.
- **`hacketyhack-*.zip` / `.tar.gz`** — the Hackety Hack tree, including Clogs
  and the Shoes 3 compatibility layer.

## Status, honestly

Clogs itself is working and tested: layout, styled and wrapped text, links,
art drawables, images, widgets, mouse and keyboard events, animation and
dialogs. See `clogs/docs/libui_shoes_coverage.md` for a tested feature-by-feature
matrix, including what libui cannot do.

Hackety Hack's **sample programs run** — `rake samples` runs the bundled Shoes
programs on Clogs and reports which ones work. The **IDE itself does not run
yet**: it depends on Shoes 3 slot-block scoping that Lacci does not reproduce.
That work is tracked in the repository README.

## Running it

```
gem install clogs
ruby -e 'require "clogs"; Shoes.app { para "Hello from Clogs" }'
```

On Linux you also need GTK3 (`apt install libgtk-3-0`); macOS and Windows need
nothing extra.
