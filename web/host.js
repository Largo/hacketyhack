// The page half of Clogs' wasm backend.
//
// Ruby owns the Shoes document, the layout and every drawing decision; this
// file owns the canvas, the 2D context, the image registry and the event
// queue. The two talk exactly twice per frame -- once in (input and the clock)
// and once out (a command buffer) -- because a call across the wasm boundary
// costs far more than any single drawing operation does. See
// clogs/lib/clogs/wasm/painter.rb for the other half of the opcode table.
(function () {
  "use strict";

  // Opcodes. These have to match Clogs::Painter's constants exactly.
  const SAVE = 1, RESTORE = 2, TRANSLATE = 3, ROTATE = 4, SCALE = 5, TRANSFORM = 6,
    BEGIN_PATH = 7, MOVE_TO = 8, LINE_TO = 9, CURVE_TO = 10, RECT = 11, ARC = 12,
    CLOSE_PATH = 13, FILL = 14, STROKE = 15, CLIP = 16, FILL_STYLE = 17,
    STROKE_STYLE = 18, LINE_WIDTH = 19, LINE_CAP = 20, LINE_JOIN = 21, LINE_DASH = 22,
    FILL_GRADIENT = 23, FILL_TEXT = 24, DRAW_IMAGE = 25, FILL_RECT = 26;

  const FILL_RULES = ["nonzero", "evenodd"];
  const CAPS = ["butt", "round", "square"];
  const JOINS = ["miter", "round", "bevel"];

  const windows = new Map();   // id -> {canvas, ctx, title}
  const images = [];           // handle -> {img, width, height}
  const imagesByKey = new Map();
  let events = [];
  let rubyTick = null;
  let rubyImageLoaded = null;
  let rubyDescribe = null;
  let running = false;
  let framesPainted = 0;
  let lastPaintedFrames = -1;

  const container = () => document.getElementById("clogs-windows") || document.body;

  function rgba(a, r, g, b, alpha) {
    return "rgba(" + r + "," + g + "," + b + "," + (alpha / 255) + ")";
  }

  // ---- measurement ----------------------------------------------------
  // One offscreen context, kept only for measureText. Ruby caches the answers,
  // so this is called far less often than a frame.
  const measureCanvas = document.createElement("canvas");
  const measureCtx = measureCanvas.getContext("2d");

  // ---- the command buffer ---------------------------------------------

  function replay(ctx, ops, strings) {
    let i = 0;
    const n = ops.length;
    ctx.textBaseline = "alphabetic";
    while (i < n) {
      switch (ops[i++]) {
        case SAVE: ctx.save(); break;
        case RESTORE: ctx.restore(); break;
        case TRANSLATE: ctx.translate(ops[i++], ops[i++]); break;
        case ROTATE: ctx.rotate(ops[i++]); break;
        case SCALE: ctx.scale(ops[i++], ops[i++]); break;
        case TRANSFORM: ctx.transform(ops[i++], ops[i++], ops[i++], ops[i++], ops[i++], ops[i++]); break;
        case BEGIN_PATH: ctx.beginPath(); break;
        case MOVE_TO: ctx.moveTo(ops[i++], ops[i++]); break;
        case LINE_TO: ctx.lineTo(ops[i++], ops[i++]); break;
        case CURVE_TO: ctx.bezierCurveTo(ops[i++], ops[i++], ops[i++], ops[i++], ops[i++], ops[i++]); break;
        case RECT: ctx.rect(ops[i++], ops[i++], ops[i++], ops[i++]); break;
        case ARC: {
          const cx = ops[i++], cy = ops[i++], r = ops[i++], a0 = ops[i++], a1 = ops[i++], ccw = ops[i++];
          ctx.arc(cx, cy, Math.abs(r), a0, a1, ccw === 1);
          break;
        }
        case CLOSE_PATH: ctx.closePath(); break;
        case FILL: ctx.fill(FILL_RULES[ops[i++]] || "nonzero"); break;
        case STROKE: ctx.stroke(); break;
        case CLIP: ctx.clip(FILL_RULES[ops[i++]] || "nonzero"); break;
        case FILL_STYLE: ctx.fillStyle = rgba(0, ops[i++], ops[i++], ops[i++], ops[i++]); break;
        case STROKE_STYLE: ctx.strokeStyle = rgba(0, ops[i++], ops[i++], ops[i++], ops[i++]); break;
        case LINE_WIDTH: ctx.lineWidth = ops[i++]; break;
        case LINE_CAP: ctx.lineCap = CAPS[ops[i++]] || "butt"; break;
        case LINE_JOIN: ctx.lineJoin = JOINS[ops[i++]] || "miter"; break;
        case LINE_DASH: {
          const count = ops[i++];
          const dashes = [];
          for (let d = 0; d < count; d++) dashes.push(ops[i++]);
          ctx.setLineDash(dashes);
          break;
        }
        case FILL_GRADIENT: {
          const x0 = ops[i++], y0 = ops[i++], x1 = ops[i++], y1 = ops[i++], stops = ops[i++];
          const grad = ctx.createLinearGradient(x0, y0, x1, y1);
          for (let s = 0; s < stops; s++) {
            const pos = ops[i++];
            grad.addColorStop(Math.min(1, Math.max(0, pos)), rgba(0, ops[i++], ops[i++], ops[i++], ops[i++]));
          }
          ctx.fillStyle = grad;
          break;
        }
        case FILL_TEXT: {
          const font = strings[ops[i++]];
          const text = strings[ops[i++]];
          ctx.font = font;
          ctx.fillText(text, ops[i++], ops[i++]);
          break;
        }
        case DRAW_IMAGE: {
          const entry = images[ops[i++]];
          const x = ops[i++], y = ops[i++], w = ops[i++], h = ops[i++];
          if (entry && entry.ready) ctx.drawImage(entry.img, x, y, w, h);
          break;
        }
        case FILL_RECT: ctx.fillRect(ops[i++], ops[i++], ops[i++], ops[i++]); break;
        default:
          // An opcode the page does not know means the two tables have drifted;
          // there is no way to resynchronise mid-buffer, so say so and stop.
          console.error("ClogsHost: unknown opcode at " + (i - 1), ops[i - 1]);
          return;
      }
    }
  }

  // ---- input ----------------------------------------------------------

  function modifiersOf(e) {
    return (e.ctrlKey ? 1 : 0) | (e.altKey ? 2 : 0) | (e.shiftKey ? 4 : 0) | (e.metaKey ? 8 : 0);
  }

  // DOM buttons is left=1, right=2, middle=4; Clogs (following libui) wants
  // left=1, middle=2, right=4.
  function heldOf(buttons) {
    return ((buttons & 1) ? 1 : 0) | ((buttons & 4) ? 2 : 0) | ((buttons & 2) ? 4 : 0);
  }

  function buttonOf(button) {
    return button === 0 ? 1 : button === 1 ? 2 : button === 2 ? 3 : button + 1;
  }

  function pushMouse(id, e, down, up) {
    const rect = e.target.getBoundingClientRect();
    const x = e.clientX - rect.left;
    const y = e.clientY - rect.top;
    const held = heldOf(e.buttons);
    // Two mouse positions in one frame are of no use to anybody, so a motion
    // event replaces the motion event before it rather than queueing behind it.
    const last = events[events.length - 1];
    if (down === 0 && up === 0 && last && last[0] === "m" && last[1] === id && last[4] === 0 && last[5] === 0) {
      events[events.length - 1] = ["m", id, x, y, 0, 0, modifiersOf(e), held];
      return;
    }
    events.push(["m", id, x, y, down, up, modifiersOf(e), held]);
  }

  function bindEvents(id, canvas) {
    canvas.addEventListener("mousemove", (e) => pushMouse(id, e, 0, 0));
    canvas.addEventListener("mousedown", (e) => {
      canvas.focus();
      // The DOM reports buttons as they are *during* the press, unlike GTK, so
      // the bitmask needs no fixing up here.
      pushMouse(id, e, buttonOf(e.button), 0);
      e.preventDefault();
    });
    canvas.addEventListener("mouseup", (e) => pushMouse(id, e, 0, buttonOf(e.button)));
    canvas.addEventListener("mouseenter", () => events.push(["x", id, 0]));
    canvas.addEventListener("mouseleave", () => events.push(["x", id, 1]));
    canvas.addEventListener("contextmenu", (e) => e.preventDefault());
    canvas.addEventListener("keydown", (e) => {
      events.push(["k", id, e.key, modifiersOf(e), 0]);
      // Let the browser keep its own shortcuts, but not scroll the page out
      // from under an app that wants the arrow keys.
      if (!e.metaKey && !e.ctrlKey) e.preventDefault();
    });
    canvas.addEventListener("keyup", (e) => events.push(["k", id, e.key, modifiersOf(e), 1]));
  }

  // ---- the frame clock ------------------------------------------------

  // One clock, shared by the page's animation frames and by a test driving by
  // hand, and monotonic across both: Ruby schedules its timers against it, so
  // it must never go backwards when a test advances it past real time.
  let clock = 0;

  function frame(now) {
    if (running) requestAnimationFrame(frame);
    clock = Math.max(clock, now);
    pump(clock);
  }

  function pump(now) {
    if (!rubyTick) return 0;
    const batch = events;
    events = [];
    const painted = rubyTick(now, batch.length ? JSON.stringify(batch) : "[]");
    framesPainted += (painted | 0);
    return painted | 0;
  }

  // ---- the host object ------------------------------------------------

  const ClogsHost = {
    // -- called from Ruby --

    onTick(fn) { rubyTick = fn; if (!running) { running = true; requestAnimationFrame(frame); } },
    onImageLoaded(fn) { rubyImageLoaded = fn; },
    onDescribe(fn) { rubyDescribe = fn; },

    openWindow(id, title, width, height) {
      const canvas = document.createElement("canvas");
      canvas.width = width;
      canvas.height = height;
      canvas.className = "clogs-window";
      canvas.tabIndex = 0;
      canvas.dataset.clogsWindow = String(id);
      canvas.dataset.clogsTitle = title;
      container().appendChild(canvas);
      bindEvents(id, canvas);
      windows.set(id, { canvas, ctx: canvas.getContext("2d"), title });
      document.title = title;
      canvas.focus();
      return id;
    },

    closeWindow(id) {
      const win = windows.get(id);
      if (win) win.canvas.remove();
      windows.delete(id);
    },

    windowSize(id) {
      const win = windows.get(id);
      return win ? win.canvas.width + "," + win.canvas.height : "0,0";
    },

    setCursor(id, cursor) {
      const win = windows.get(id);
      if (win) win.canvas.style.cursor = cursor;
    },

    flush(id, opsJson, stringsJson) {
      const win = windows.get(id);
      if (!win) return;
      replay(win.ctx, JSON.parse(opsJson), JSON.parse(stringsJson));
    },

    measureText(text, font) {
      measureCtx.font = font;
      const m = measureCtx.measureText(text);
      // fontBoundingBox* is the line box -- the same thing Pango calls the
      // logical extent, and what the native backends measure -- rather than
      // the ink of these particular glyphs.
      const ascent = m.fontBoundingBoxAscent !== undefined ? m.fontBoundingBoxAscent : m.actualBoundingBoxAscent;
      const descent = m.fontBoundingBoxDescent !== undefined ? m.fontBoundingBoxDescent : m.actualBoundingBoxDescent;
      return m.width + "," + (ascent || 0) + "," + (descent || 0);
    },

    loadImage(key, dataUrl) {
      if (imagesByKey.has(key)) return imagesByKey.get(key);
      const handle = images.length;
      const entry = { img: new Image(), width: 0, height: 0, ready: false };
      images.push(entry);
      imagesByKey.set(key, handle);
      entry.img.onload = () => {
        entry.width = entry.img.naturalWidth;
        entry.height = entry.img.naturalHeight;
        entry.ready = true;
        if (rubyImageLoaded) rubyImageLoaded();
      };
      entry.img.onerror = () => { console.warn("ClogsHost: image failed to load", key); };
      entry.img.src = dataUrl;
      return handle;
    },

    imageSize(handle) {
      const entry = images[handle];
      return entry && entry.ready ? entry.width + "," + entry.height : "0,0";
    },

    alert(message) { window.alert(message); },
    confirm(message) { return window.confirm(message); },
    ask(message) { return window.prompt(message); },

    // navigator.clipboard is asynchronous and permission-gated; Shoes' own
    // clipboard is neither. The page keeps what Clogs last copied so that copy
    // and paste inside a Shoes program work, and writes through to the system
    // clipboard opportunistically for everything outside it.
    clipboardRead() { return this._clipboard || ""; },
    clipboardWrite(text) {
      this._clipboard = text;
      if (navigator.clipboard && navigator.clipboard.writeText) {
        navigator.clipboard.writeText(text).catch(() => {});
      }
    },
    _clipboard: "",
  };

  // ---- the automation surface -----------------------------------------
  //
  // Clogs paints a Shoes document into a single canvas, so a page under
  // Playwright has pixels and nothing else: no elements to select, no text to
  // read. `window.clogs` is the way back in -- the drawable tree with its
  // geometry, input that lands on the app rather than on the DOM, and a clock
  // a test can drive by hand instead of waiting on.
  const clogs = {
    get ready() { return window.__clogsReady; },

    windows() {
      return Array.from(windows.entries()).map(([id, w]) => ({
        id, title: w.title, width: w.canvas.width, height: w.canvas.height,
      }));
    },

    // Run the frame loop by hand: input in, timers fired, frames painted.
    // Returns how many canvases repainted, so `settle` can tell "nothing left
    // to do" from "still animating".
    tick(times = 1, advanceMs = 16) {
      let painted = 0;
      for (let i = 0; i < times; i++) {
        clock += advanceMs;
        painted += pump(clock);
      }
      return painted;
    },

    // Run `ms` of the app's own time, in 16ms frames. An animation, a Shoes
    // `every` and Hackety Hack's splash sequence all move by exactly as much
    // as this says, however fast or slow the machine underneath is.
    advance(ms, stepMs = 16) {
      return this.tick(Math.max(1, Math.ceil(ms / stepMs)), stepMs);
    },

    clock() { return clock; },

    // Tick until nothing repaints, or until the budget runs out. An animating
    // app never settles, which is why this reports rather than throws -- and
    // why the budget is small: a resting app stops on the first or second
    // tick, and for one that never rests every remaining tick is a frame of
    // real work spent finding that out again.
    settle(maxTicks = 12) {
      for (let i = 0; i < maxTicks; i++) {
        if (this.tick(1) === 0) return { settled: true, ticks: i + 1 };
      }
      return { settled: false, ticks: maxTicks };
    },

    // The drawable tree, straight out of Ruby: types, geometry and text.
    describe(windowId = null) {
      if (!rubyDescribe) return null;
      return JSON.parse(rubyDescribe(windowId === null ? 0 : windowId));
    },

    // Find drawables by the words on them, or by Shoes class name. Returns
    // every match with the centre point to aim at, because "the second Ready"
    // is a real thing to want and guessing is not.
    find(query, windowId = null) {
      const tree = this.describe(windowId);
      const hits = [];
      const wanted = query instanceof RegExp ? query : String(query);
      const matches = (node) => {
        if (wanted instanceof RegExp) return wanted.test(node.text || "") || wanted.test(node.type || "");
        return (node.text || "").includes(wanted) || node.type === wanted;
      };
      (function walk(node) {
        if (!node) return;
        if (matches(node) && node.width > 0 && node.height > 0) {
          hits.push(Object.assign({}, node, {
            children: undefined,
            centerX: node.x + node.width / 2,
            centerY: node.y + node.height / 2,
          }));
        }
        (node.children || []).forEach(walk);
      })(tree && tree.drawables);
      return hits;
    },

    // Click whatever says this. Throws rather than silently missing, since a
    // click into empty canvas looks exactly like a click that did nothing.
    clickText(query, { index = 0, windowId = 1 } = {}) {
      const hits = this.find(query, windowId === 1 ? null : windowId);
      if (!hits.length) throw new Error(`clogs.clickText: nothing matching ${query}`);
      const hit = hits[index];
      if (!hit) throw new Error(`clogs.clickText: only ${hits.length} matches for ${query}`);
      this.click(hit.centerX, hit.centerY, windowId);
      return hit;
    },

    // Everything a test needs to pretend to be a person. Each of these leaves
    // the event queued; `tick` is what delivers it, so a test controls exactly
    // which frame an input lands on.
    // The three primitives everything else is built from. `held` is the
    // button bitmask the app sees *during* the event -- Shoes programs like
    // Scribble read it straight off `self.mouse` rather than waiting for a
    // click, so a drag has to keep it set across the frames it spans.
    moveMouse(x, y, windowId = 1, held = 0) {
      events.push(["m", windowId, x, y, 0, 0, 0, held]);
      return this;
    },

    mouseDown(x, y, windowId = 1, button = 1) {
      events.push(["m", windowId, x, y, button, 0, 0, 1 << (button - 1)]);
      return this;
    },

    mouseUp(x, y, windowId = 1, button = 1) {
      events.push(["m", windowId, x, y, 0, button, 0, 0]);
      return this;
    },

    click(x, y, windowId = 1) {
      this.moveMouse(x, y, windowId);
      this.mouseDown(x, y, windowId);
      this.mouseUp(x, y, windowId);
      return this;
    },

    // Press, move, release: the shape of every drawing gesture in Shoes.
    // `points` is [[x, y], ...]; the button is held for all of it.
    // Press, move, release. `stepMs` runs that much of the app's own time
    // between steps: a program that draws from a timer rather than from the
    // motion event needs frames to happen while the button is down, and with
    // stepMs at 0 the whole gesture lands inside a single frame.
    drag(points, { windowId = 1, stepMs = 0 } = {}) {
      if (!points.length) return this;
      const [first] = points;
      this.moveMouse(first[0], first[1], windowId);
      this.mouseDown(first[0], first[1], windowId);
      for (const [x, y] of points.slice(1)) {
        if (stepMs > 0) this.advance(stepMs);
        this.moveMouse(x, y, windowId, 1);
      }
      if (stepMs > 0) this.advance(stepMs);
      const last = points[points.length - 1];
      this.mouseUp(last[0], last[1], windowId);
      return this;
    },

    key(name, windowId = 1, modifiers = 0) {
      events.push(["k", windowId, name, modifiers, 0]);
      events.push(["k", windowId, name, modifiers, 1]);
      return this;
    },

    type(text, windowId = 1) {
      for (const ch of text) this.key(ch, windowId);
      return this;
    },

    framesPainted() { return framesPainted; },

    // Stop the page's own animation frames so a test owns the clock outright.
    pause() { running = false; return this; },
    resume() { if (!running) { running = true; requestAnimationFrame(frame); } return this; },
    paused() { return !running; },
  };

  window.ClogsHost = ClogsHost;
  window.clogs = clogs;
})();
