# frozen_string_literal: true

require_relative "ui"

module Clogs
  # A path under construction.
  #
  # Recorded rather than drawn, for the same reasons as on the gtk3 backend:
  # it is what lets Clogs fill *and* stroke one path, and what lets Image keep
  # a path across frames. Here it is also what lets a path be replayed into the
  # command buffer at flush time rather than talked to the page op by op.
  class Path
    attr_reader :fill_mode, :ops

    def initialize(fill_mode = UI::WINDING)
      @fill_mode = fill_mode
      @ops = []
      @live = true
    end

    def ptr
      @live ? self : nil
    end

    def move_to(x, y)
      @ops << [:move_to, x.to_f, y.to_f]
      self
    end

    def line_to(x, y)
      @ops << [:line_to, x.to_f, y.to_f]
      self
    end

    def curve_to(c1x, c1y, c2x, c2y, x, y)
      @ops << [:curve_to, c1x.to_f, c1y.to_f, c2x.to_f, c2y.to_f, x.to_f, y.to_f]
      self
    end

    # Canvas 2D measures angles the way Cairo does and the way Clogs' shapes
    # are written against: from the positive x axis, increasing towards
    # positive y, which is clockwise on screen. Nothing to convert.
    def arc_to(cx, cy, radius, start_angle, sweep, negative = false)
      @ops << [:arc, cx.to_f, cy.to_f, radius.to_f, start_angle.to_f, sweep.to_f, negative]
      self
    end

    # Cairo's new_sub_path drops the current point so an arc does not connect
    # to whatever came before it. Canvas 2D has no such call -- `arc` always
    # draws a line in from the current point -- so the marker is recorded here
    # and resolved into an explicit moveTo at replay time, which is what Cairo
    # does internally anyway.
    def arc_figure(cx, cy, radius, start_angle, sweep, negative = false)
      @ops << [:new_sub_path]
      arc_to(cx, cy, radius, start_angle, sweep, negative)
    end

    def rect(x, y, w, h)
      @ops << [:rect, x.to_f, y.to_f, w.to_f, h.to_f]
      self
    end

    K = 0.5522847498307936
    def oval(x, y, w, h)
      rx = w / 2.0
      ry = h / 2.0
      cx = x + rx
      cy = y + ry
      move_to(cx + rx, cy)
      curve_to(cx + rx, cy + ry * K, cx + rx * K, cy + ry, cx, cy + ry)
      curve_to(cx - rx * K, cy + ry, cx - rx, cy + ry * K, cx - rx, cy)
      curve_to(cx - rx, cy - ry * K, cx - rx * K, cy - ry, cx, cy - ry)
      curve_to(cx + rx * K, cy - ry, cx + rx, cy - ry * K, cx + rx, cy)
      close
    end

    def close
      @ops << [:close_path]
      self
    end

    def end!
      self
    end

    def empty?
      @ops.empty?
    end

    def free
      @live = false
      @ops = []
    end
  end

  # An immediate-mode drawing surface that writes to a command buffer.
  #
  # Every other backend hands each drawing call straight to a library. This one
  # cannot: a call from wasm into JS costs about ten microseconds, and a frame
  # of Hackety Hack is thousands of calls, so drawing op by op would spend more
  # time crossing the boundary than the browser spends painting. Instead each
  # call appends numbers to a flat array which is handed over once per frame
  # (see Bridge.flush) and replayed by web/host.js.
  #
  # The array is flat and all-numeric on purpose -- a nested or mixed-type
  # array costs several times as much to serialise. Ops that need a string
  # carry an index into a side table instead.
  class Painter
    WINDING = UI::WINDING
    ALTERNATE = UI::ALTERNATE
    IDENTITY = [1.0, 0.0, 0.0, 1.0, 0.0, 0.0].freeze

    # Opcodes. web/host.js has the matching switch; the two tables have to
    # agree, so they are named the same on both sides.
    OP_SAVE = 1
    OP_RESTORE = 2
    OP_TRANSLATE = 3
    OP_ROTATE = 4
    OP_SCALE = 5
    OP_TRANSFORM = 6
    OP_BEGIN_PATH = 7
    OP_MOVE_TO = 8
    OP_LINE_TO = 9
    OP_CURVE_TO = 10
    OP_RECT = 11
    OP_ARC = 12
    OP_CLOSE_PATH = 13
    OP_FILL = 14
    OP_STROKE = 15
    OP_CLIP = 16
    OP_FILL_STYLE = 17
    OP_STROKE_STYLE = 18
    OP_LINE_WIDTH = 19
    OP_LINE_CAP = 20
    OP_LINE_JOIN = 21
    OP_LINE_DASH = 22
    OP_FILL_GRADIENT = 23
    OP_FILL_TEXT = 24
    OP_DRAW_IMAGE = 25
    OP_FILL_RECT = 26

    attr_reader :ops, :strings, :width, :height

    def initialize(width, height)
      @width = width
      @height = height
      @ops = []
      @strings = []
      @string_ids = {}
      @ctm = [IDENTITY]
      @clip = [[0, 0, width, height]]
    end

    # Strings are interned so a page full of the same font description costs
    # one table entry and an integer per use.
    def intern(str)
      @string_ids[str] ||= begin
        @strings << str
        @strings.size - 1
      end
    end

    # ---- transform stack ----------------------------------------------

    def save
      @ops << OP_SAVE
      @ctm.push(@ctm.last)
      @clip.push(@clip.last)
      yield self
    ensure
      @ops << OP_RESTORE
      @ctm.pop
      @clip.pop
    end

    def translate(x, y)
      return if x.zero? && y.zero?

      @ops.push(OP_TRANSLATE, x.to_f, y.to_f)
      concat([1.0, 0.0, 0.0, 1.0, x.to_f, y.to_f])
    end

    def rotate(degrees, cx = 0, cy = 0)
      rad = degrees * Math::PI / 180.0
      around(cx, cy) do
        @ops.push(OP_ROTATE, rad)
        [Math.cos(rad), Math.sin(rad), -Math.sin(rad), Math.cos(rad), 0.0, 0.0]
      end
    end

    def scale(sx, sy, cx = 0, cy = 0)
      around(cx, cy) do
        @ops.push(OP_SCALE, sx.to_f, sy.to_f)
        [sx.to_f, 0.0, 0.0, sy.to_f, 0.0, 0.0]
      end
    end

    def skew(ax, ay, cx = 0, cy = 0)
      tx = Math.tan(ax * Math::PI / 180.0)
      ty = Math.tan(ay * Math::PI / 180.0)
      around(cx, cy) do
        @ops.push(OP_TRANSFORM, 1.0, ty, tx, 1.0, 0.0, 0.0)
        [1.0, ty, tx, 1.0, 0.0, 0.0]
      end
    end

    def apply(x, y)
      a, b, c, d, e, f = @ctm.last
      [a * x + c * y + e, b * x + d * y + f]
    end

    # ---- clipping ------------------------------------------------------

    def visible?(x, y, w, h)
      x0, y0, x1, y1 = device_bounds(x, y, w, h)
      cx, cy, cw, ch = @clip.last
      x0 < cx + cw && x1 > cx && y0 < cy + ch && y1 > cy
    end

    # The canvas intersects with the clip already in force and restores it on
    # restore, so the tracked rectangle only follows along for `visible?`.
    def clip_rect(x, y, w, h)
      @ops.push(OP_BEGIN_PATH, OP_RECT, x.to_f, y.to_f, w.to_f, h.to_f, OP_CLIP, WINDING)
      x0, y0, x1, y1 = device_bounds(x, y, w, h)
      cx, cy, cw, ch = @clip.last
      nx0 = [x0, cx].max
      ny0 = [y0, cy].max
      nx1 = [x1, cx + cw].min
      ny1 = [y1, cy + ch].min
      @clip[-1] = [nx0, ny0, [nx1 - nx0, 0].max, [ny1 - ny0, 0].max]
    end

    # ---- fills and strokes ---------------------------------------------

    def fill_rect(x, y, w, h, paint)
      return if w <= 0 || h <= 0 || paint.nil?
      return unless visible?(x, y, w, h)

      set_fill(paint, x, y, w, h)
      @ops.push(OP_FILL_RECT, x.to_f, y.to_f, w.to_f, h.to_f)
    end

    def stroke_rect(x, y, w, h, paint, thickness: 1)
      draw(stroke: paint, thickness: thickness) { |p| p.rect(x, y, w, h) }
    end

    def fill_oval(x, y, w, h, paint)
      return if paint.nil?
      return unless visible?(x, y, w, h)

      draw(fill: paint) { |p| p.oval(x, y, w, h) }
    end

    def stroke_oval(x, y, w, h, paint, thickness: 1)
      draw(stroke: paint, thickness: thickness) { |p| p.oval(x, y, w, h) }
    end

    def line(x1, y1, x2, y2, paint, thickness: 1, cap: UI::CAP_FLAT)
      draw(stroke: paint, thickness: thickness, cap: cap) do |p|
        p.move_to(x1, y1).line_to(x2, y2)
      end
    end

    # The workhorse: build a path in the block, then fill and/or stroke it.
    # A canvas path survives its own fill, so both come off one path.
    def draw(fill: nil, stroke: nil, thickness: 1, cap: UI::CAP_FLAT, join: UI::JOIN_MITER,
      dashes: nil, fill_mode: WINDING)
      path = Path.new(fill_mode)
      yield path
      path.end!
      return if path.empty?

      if fill && stroke
        replay(path)
        set_fill(fill, *path_box(path))
        @ops.push(OP_FILL, path.fill_mode)
        apply_stroke_style(thickness, cap, join, dashes)
        set_stroke(stroke, *path_box(path))
        @ops << OP_STROKE
      elsif fill
        fill_path(path, fill)
      elsif stroke
        stroke_path(path, stroke, thickness: thickness, cap: cap, join: join, dashes: dashes)
      end
    end

    def fill_path(path, paint)
      return if path.nil? || path.ptr.nil? || paint.nil? || path.empty?

      replay(path)
      set_fill(paint, *path_box(path))
      @ops.push(OP_FILL, path.fill_mode)
    end

    def stroke_path(path, paint, thickness: 1, cap: UI::CAP_FLAT, join: UI::JOIN_MITER, dashes: nil)
      return if path.nil? || path.ptr.nil? || paint.nil? || path.empty?

      replay(path)
      apply_stroke_style(thickness, cap, join, dashes)
      set_stroke(paint, *path_box(path))
      @ops << OP_STROKE
    end

    def draw_text(layout, x, y)
      layout.render(self, x, y)
    end

    # One text piece, at a baseline. TextBlock has already done the layout;
    # this is the only op that reaches the string table.
    def fill_text(text, font, color, x, y)
      set_fill(color, x, y, 0, 0)
      @ops.push(OP_FILL_TEXT, intern(font), intern(text), x.to_f, y.to_f)
    end

    # Bitmaps, by handle: the page holds the decoded image and Ruby only ever
    # names it. See Bridge.load_image for why the handle can outrun the pixels.
    def draw_image(handle, x, y, width, height)
      return if handle.nil? || handle < 0

      @ops.push(OP_DRAW_IMAGE, handle, x.to_f, y.to_f, width.to_f, height.to_f)
    end

    private

    def replay(path)
      @ops << OP_BEGIN_PATH
      pending_sub_path = false
      path.ops.each do |op, *a|
        case op
        when :move_to then @ops.push(OP_MOVE_TO, a[0], a[1])
        when :line_to then @ops.push(OP_LINE_TO, a[0], a[1])
        when :curve_to then @ops.push(OP_CURVE_TO, *a)
        when :rect then @ops.push(OP_RECT, a[0], a[1], a[2], a[3])
        when :close_path then @ops << OP_CLOSE_PATH
        when :new_sub_path then pending_sub_path = true
        when :arc
          cx, cy, radius, start_angle, sweep, negative = a
          # Canvas 2D takes an end angle and a direction, not a sweep.
          ccw = negative || sweep.negative?
          finish = negative ? start_angle - sweep : start_angle + sweep
          if pending_sub_path
            @ops.push(OP_MOVE_TO, cx + radius * Math.cos(start_angle), cy + radius * Math.sin(start_angle))
            pending_sub_path = false
          end
          @ops.push(OP_ARC, cx, cy, radius, start_angle, finish, ccw ? 1 : 0)
        end
      end
    end

    def apply_stroke_style(thickness, cap, join, dashes)
      @ops.push(OP_LINE_WIDTH, thickness <= 0 ? 1.0 : thickness.to_f)
      @ops.push(OP_LINE_CAP, cap)
      @ops.push(OP_LINE_JOIN, join)
      if dashes && !dashes.empty?
        @ops.push(OP_LINE_DASH, dashes.size, *dashes.map(&:to_f))
      else
        @ops.push(OP_LINE_DASH, 0)
      end
    end

    def set_fill(paint, x = 0, y = 0, _w = 0, h = 0)
      if paint.is_a?(UI::Gradient)
        # `background a..b` in Shoes runs its gradient down the drawable's box.
        @ops.push(OP_FILL_GRADIENT, x.to_f, y.to_f, x.to_f, y.to_f + h, paint.stops.size)
        paint.stops.each { |pos, color| @ops.push(pos, *UI.rgba(color)) }
      else
        @ops.push(OP_FILL_STYLE, *UI.rgba(paint.is_a?(UI::Solid) ? paint.rgba : paint))
      end
    end

    def set_stroke(paint, _x = 0, _y = 0, _w = 0, _h = 0)
      # A stroked gradient is not something Shoes asks for; the first stop is
      # a better answer than dropping the stroke entirely.
      rgba = if paint.is_a?(UI::Gradient)
        paint.stops.first&.last || [0, 0, 0, 255]
      elsif paint.is_a?(UI::Solid)
        paint.rgba
      else
        paint
      end
      @ops.push(OP_STROKE_STYLE, *UI.rgba(rgba))
    end

    # The path's own bounding box, for a gradient to run across.
    def path_box(path)
      xs = []
      ys = []
      path.ops.each do |op, *a|
        case op
        when :move_to, :line_to then xs << a[0]; ys << a[1]
        when :curve_to
          xs.push(a[0], a[2], a[4])
          ys.push(a[1], a[3], a[5])
        when :rect
          xs.push(a[0], a[0] + a[2])
          ys.push(a[1], a[1] + a[3])
        when :arc
          xs.push(a[0] - a[2], a[0] + a[2])
          ys.push(a[1] - a[2], a[1] + a[2])
        end
      end
      return [0, 0, 0, 0] if xs.empty?

      [xs.min, ys.min, xs.max - xs.min, ys.max - ys.min]
    end

    def concat(local)
      a, b, c, d, e, f = @ctm.last
      la, lb, lc, ld, le, lf = local
      @ctm[-1] = [
        a * la + c * lb,
        b * la + d * lb,
        a * lc + c * ld,
        b * lc + d * ld,
        a * le + c * lf + e,
        b * le + d * lf + f
      ]
    end

    def around(cx, cy)
      translate(cx, cy)
      concat(yield)
      translate(-cx, -cy)
    end

    def device_bounds(x, y, w, h)
      corners = [[x, y], [x + w, y], [x + w, y + h], [x, y + h]].map { |px, py| apply(px, py) }
      xs = corners.map(&:first)
      ys = corners.map(&:last)
      [xs.min, ys.min, xs.max, ys.max]
    end
  end
end
