# frozen_string_literal: true

require_relative "ui"

module Clogs
  # A path under construction.
  #
  # Cairo builds its path on the context rather than in a standalone object, so
  # this records the calls and replays them when the path is filled or stroked.
  # Recording rather than drawing immediately is also what lets Clogs fill
  # *and* stroke the same path, and what lets Image keep one across frames.
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

    # Cairo's angles are Clogs' angles: measured from the positive x axis and
    # increasing towards positive y, which is clockwise on screen. libui's
    # drawing API is a wrapper over this one, so the convention Clogs' shapes
    # are written against needs no conversion here at all.
    def arc_to(cx, cy, radius, start_angle, sweep, negative = false)
      @ops << [:arc, cx.to_f, cy.to_f, radius.to_f, start_angle.to_f, sweep.to_f, negative]
      self
    end

    # Cairo's new_sub_path is exactly libui's "begin a figure with an arc": it
    # drops the current point so the arc does not connect to the last one.
    def arc_figure(cx, cy, radius, start_angle, sweep, negative = false)
      @ops << [:new_sub_path]
      arc_to(cx, cy, radius, start_angle, sweep, negative)
    end

    def rect(x, y, w, h)
      @ops << [:rectangle, x.to_f, y.to_f, w.to_f, h.to_f]
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

    # Replay onto a Cairo context.
    def replay(cr)
      @ops.each do |op, *args|
        case op
        when :move_to then cr.move_to(args[0], args[1])
        when :line_to then cr.line_to(args[0], args[1])
        when :curve_to then cr.curve_to(*args)
        when :rectangle then cr.rectangle(args[0], args[1], args[2], args[3])
        when :new_sub_path then cr.new_sub_path
        when :close_path then cr.close_path
        when :arc
          cx, cy, radius, start_angle, sweep, negative = args
          if negative
            cr.arc_negative(cx, cy, radius, start_angle, start_angle - sweep)
          elsif sweep.negative?
            cr.arc_negative(cx, cy, radius, start_angle, start_angle + sweep)
          else
            cr.arc(cx, cy, radius, start_angle, start_angle + sweep)
          end
        end
      end
    end

    def free
      @live = false
      @ops = []
    end
  end

  # An immediate-mode drawing surface over a Cairo context.
  #
  # This is the shortest painter of the five, because it is the one talking to
  # the library the others are wrappers over. Every method is one or two Cairo
  # calls, and nothing about Shoes' drawing model has to be approximated.
  class Painter
    WINDING = UI::WINDING
    ALTERNATE = UI::ALTERNATE
    IDENTITY = [1.0, 0.0, 0.0, 1.0, 0.0, 0.0].freeze

    attr_reader :cr, :width, :height

    def initialize(cr, width, height)
      @cr = cr
      @width = width
      @height = height
      @ctm = [IDENTITY]
      @clip = [[0, 0, width, height]]
    end

    # ---- transform stack ----------------------------------------------

    def save
      @cr.save
      @ctm.push(@ctm.last)
      @clip.push(@clip.last)
      yield self
    ensure
      @cr.restore
      @ctm.pop
      @clip.pop
    end

    def translate(x, y)
      return if x.zero? && y.zero?

      @cr.translate(x, y)
      concat([1.0, 0.0, 0.0, 1.0, x.to_f, y.to_f])
    end

    def rotate(degrees, cx = 0, cy = 0)
      rad = degrees * Math::PI / 180.0
      around(cx, cy) do
        @cr.rotate(rad)
        [Math.cos(rad), Math.sin(rad), -Math.sin(rad), Math.cos(rad), 0.0, 0.0]
      end
    end

    def scale(sx, sy, cx = 0, cy = 0)
      around(cx, cy) do
        @cr.scale(sx, sy)
        [sx.to_f, 0.0, 0.0, sy.to_f, 0.0, 0.0]
      end
    end

    def skew(ax, ay, cx = 0, cy = 0)
      tx = Math.tan(ax * Math::PI / 180.0)
      ty = Math.tan(ay * Math::PI / 180.0)
      around(cx, cy) do
        @cr.transform(Cairo::Matrix.new(1.0, ty, tx, 1.0, 0.0, 0.0))
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

    # Cairo intersects with the clip already in force and restores it on
    # restore, so the tracked rectangle only follows along for `visible?`.
    def clip_rect(x, y, w, h)
      @cr.rectangle(x, y, w, h)
      @cr.clip
      @cr.new_path
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

      set_source(paint, x, y, w, h)
      @cr.rectangle(x, y, w, h)
      @cr.fill
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
    # Cairo can do both from one path with fill_preserve.
    def draw(fill: nil, stroke: nil, thickness: 1, cap: UI::CAP_FLAT, join: UI::JOIN_MITER,
      dashes: nil, fill_mode: WINDING)
      path = Path.new(fill_mode)
      yield path
      path.end!
      return if path.empty?

      if fill && stroke
        replay(path)
        set_source(fill, *path_box(path))
        @cr.fill_preserve
        apply_stroke_style(thickness, cap, join, dashes)
        set_source(stroke, *path_box(path))
        @cr.stroke
      elsif fill
        fill_path(path, fill)
      elsif stroke
        stroke_path(path, stroke, thickness: thickness, cap: cap, join: join, dashes: dashes)
      end
    end

    def fill_path(path, paint)
      return if path.nil? || path.ptr.nil? || paint.nil? || path.empty?

      replay(path)
      set_source(paint, *path_box(path))
      @cr.fill
    end

    def stroke_path(path, paint, thickness: 1, cap: UI::CAP_FLAT, join: UI::JOIN_MITER, dashes: nil)
      return if path.nil? || path.ptr.nil? || paint.nil? || path.empty?

      replay(path)
      apply_stroke_style(thickness, cap, join, dashes)
      set_source(paint, *path_box(path))
      @cr.stroke
    end

    def draw_text(layout, x, y)
      layout.render(self, x, y)
    end

    # Bitmaps. Cairo composites a GdkPixbuf as a source pattern, so the
    # image's own alpha lands on whatever is already on the canvas -- and it is
    # a blit, not the tens of thousands of rectangles libui needs for the same
    # picture through the same Cairo.
    def draw_image(pixbuf, x, y, width, height)
      @cr.save
      @cr.translate(x, y)
      if width != pixbuf.width || height != pixbuf.height
        @cr.scale(width.to_f / pixbuf.width, height.to_f / pixbuf.height)
      end
      @cr.set_source_pixbuf(pixbuf, 0, 0)
      @cr.paint
      @cr.restore
    end

    private

    def replay(path)
      @cr.new_path
      @cr.fill_rule = path.fill_mode
      path.replay(@cr)
    end

    def apply_stroke_style(thickness, cap, join, dashes)
      @cr.line_width = thickness <= 0 ? 1 : thickness
      @cr.line_cap = cap
      @cr.line_join = join
      @cr.set_dash(dashes && !dashes.empty? ? dashes.map(&:to_f) : [])
    end

    def set_source(paint, x = 0, y = 0, w = 0, h = 0)
      if paint.is_a?(UI::Gradient)
        # `background a..b` in Shoes runs its gradient down the drawable's box.
        pattern = Cairo::LinearPattern.new(x, y, x, y + h)
        paint.stops.each { |pos, color| pattern.add_color_stop_rgba(pos, *UI.rgba(color)) }
        @cr.set_source(pattern)
      else
        rgba = paint.is_a?(UI::Solid) ? paint.rgba : paint
        @cr.set_source_rgba(*UI.rgba(rgba))
      end
      _ = w
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
        when :rectangle
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
