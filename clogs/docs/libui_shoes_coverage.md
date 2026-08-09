# Does Shoes fit on libui?

Short answer: **mostly, but not by using libui's widgets.**

This document records what was actually tested on libui-ng as shipped by the
`libui` gem 0.2.4 (GTK3 backend, Debian 13, Ruby 3.3). Every "yes" below was
verified by running code, not by reading headers — several things the libui
documentation and examples suggest are available turn out not to be in the
shipped library.

## The one structural problem

libui has no container that places a native control at an arbitrary `(x, y)`.
Its layout primitives are `uiBox` (stack children in one direction), `uiGrid`
and `uiForm`. Shoes' entire model is the opposite: a canvas where slots,
paragraphs, images and widgets are positioned by the layout engine, can overlap,
can be moved after creation, and can sit on top of a `background`.

There is no way to reconcile those. So Clogs paints the whole Shoes document
into a single `uiArea` and draws its own widgets, rather than mapping Shoes
drawables onto libui controls. libui is used as a drawing surface and an event
source, which is close to what Shoes 3 itself did with Cairo.

The cost is that buttons, checkboxes and text fields look like Shoes widgets
rather than native ones, and do not get platform accessibility or input-method
support. The benefit is that Shoes layout works properly, which is the whole
point.

libui's native controls are still used where they fit: menus, message boxes,
file pickers, and the `ask`/`confirm` dialogs.

## What libui gives us

Verified working:

| Capability | libui API | Notes |
|---|---|---|
| Filled and stroked paths | `uiDrawPath`, `uiDrawFill`, `uiDrawStroke` | Winding and alternate fill modes |
| Lines, rectangles, beziers, arcs | `uiDrawPath*` | Ovals are four beziers; libui arcs are circular only |
| Stroke caps, joins, dashes | `uiDrawStrokeParams` | |
| Linear and radial gradients | `uiDrawBrush` with stops | Verified with a two-stop linear gradient |
| Matrix transforms | `uiDrawMatrix*`, `uiDrawTransform` | translate, rotate, scale, skew, multiply, invert |
| Clipping | `uiDrawClip` | One-way: there is no "unclip", so it must be scoped by save/restore |
| Save / restore | `uiDrawSave`, `uiDrawRestore` | |
| Text with per-run styling | `uiAttributedString` | size, colour, family, weight, italic, underline |
| Text wrapping and measurement | `uiDrawTextLayout`, `uiDrawTextLayoutExtents` | Wraps at a given width and reports extents |
| Mouse and keyboard events | `uiAreaHandler` | Down/up/move/drag, key down/up with modifiers |
| Scrolling canvas | `uiNewScrollingArea` | |
| Timers | `uiTimer` | Drives `animate`, `every` and `timer` |
| Native menus, message boxes, file pickers | `uiMenu`, `uiMsgBox`, `uiOpenFile`, `uiSaveFile` | Menus must be built before the first window |

## What libui does not give us

| Missing | Consequence for Shoes | What Clogs does |
|---|---|---|
| **`uiDrawImage` is not exported** by the shipped library, despite being declared in the gem's FFI bindings and used in its own example | No way to blit a bitmap into a canvas | Decodes PNGs with `chunky_png` and paints them as run-length-encoded rectangles. Flat art (icons, logos, UI screenshots) costs a few rectangles per row; photographs are slow. Clogs detects `uiDrawImage` at runtime and will use it if a future build provides one |
| Text hit-testing / caret geometry on a layout | `para#hit`, text selection, editable text | Clogs does its own word-level line breaking so it knows where every word landed |
| Clipboard | `clipboard`, copy and paste in edit boxes | Shells out to `xclip`/`xsel`, `pbcopy`/`pbpaste`, or `clip`/`Get-Clipboard` |
| Strikethrough text attribute (not in the Ruby binding) | `del()` | Renders as plain text |
| Alpha-compositing groups | `mask` | Contents draw normally, without masking |
| Blur, glow, shadow | `blur`, `glow`, `shadow` | Not implemented |
| Any media support | `video`, `sound` | `video` draws a placeholder; `sound` is unimplemented |
| Shifted key reporting in areas | Typing `!` etc. | Clogs applies shift itself; the symbol table assumes a US layout, letters are correct everywhere |
| A second top-level window that shares the app | `window`, `dialog` inside a running app | Single window; `dialog` renders inside the app. `ask`/`confirm` do open real modal windows on a nested event loop |

## Verdict per Shoes feature

Working in Clogs today: `stack`, `flow`, absolute positioning, `background`
(including gradients), `border`, `para` and all the sized variants, `strong`,
`em`, `code`, `ins`, `span`, `sub`, `sup`, `link` (clickable, correctly located
even mid-paragraph), `button`, `check`, `radio`, `progress`, `edit_line`,
`edit_box`, `list_box`, `image`, `rect`, `oval`, `line`, `star`, `arc`, `shape`,
`arrow`, `fill`, `stroke`, `strokewidth`, `nofill`, `nostroke`, `rotate`,
`animate`, `every`, `timer`, `motion`, `click`, `release`, `hover`, `leave`,
`keypress`, `alert`, `confirm`, `ask`, `ask_open_file`, `ask_save_file`,
`clipboard`, `mouse`, `clear`, `append`, `hide`, `show`, `toggle`.

Not working: `video`, `sound`, `blur`, `glow`, `shadow`, `mask` (draws but does
not mask), `del` (draws without the line), multiple windows, inner slot
scrolling (only the window scrolls), and native-looking widgets.

## Why not glimmer-dsl-libui?

[glimmer-dsl-libui](https://github.com/AndyObtiva/glimmer-dsl-libui) is a mature
and much larger Ruby DSL over the same library, and bridging Shoes to it was
considered. Two things ruled it out:

1. **It pins `libui` to exactly 0.1.2.** A Shoes implementation wants the newest
   libui it can get, especially while waiting for a draw-image call.
2. **Its layout model is libui's**, which is the part that does not fit Shoes.
   The genuinely reusable piece — turning a bitmap into drawable rectangles —
   is about thirty lines, and Clogs implements the same idea with run-length
   encoding rather than one rectangle per pixel.

It also brings in `glimmer`, `super_module`, `perfect-shape`, `rouge`,
`equalizer`, `os`, `color` and `text-table`, which is a lot of surface area for
an app that wants to be packaged and handed to a beginner.

Clogs therefore uses the `libui` gem directly, and takes the Shoes API itself
from Lacci — which is the part of Scarpe worth reusing.
