# frozen_string_literal: true

require_relative "ui"

module Clogs
  # A path under construction.
  #
  # Unlike the FOX backend, which has to keep geometry in Ruby because FXDC has
  # no path object at all, this wraps a real `Wx::GraphicsPath`.
  #
  # The path is asked of the graphics context that is going to draw it rather
  # than of the renderer. Building one from `GraphicsRenderer#create_path`
  # works for a while and then segfaults under load -- Pong, which builds a
  # path per drawable per frame, dies inside `create_path` with a null
  # dereference -- because nothing on the Ruby side keeps the renderer's
  # objects alive. A context-owned path lives exactly as long as the frame that
  # draws it, which is all Clogs needs.
  class Path
    attr_reader :handle, :fill_mode

    def initialize(fill_mode = UI::WINDING, gc = nil)
      @fill_mode = fill_mode
      @handle = (gc || Painter.renderer).create_path
      @started = false
      @live = true
    end

    # Image checks `ptr.nil?` before drawing a path it kept from an earlier
    # frame; that is the libui backend's name for "still alive".
    def ptr
      @live ? @handle : nil
    end

    def move_to(x, y)
      @handle.move_to_point(x, y)
      @started = true
      self
    end

    def line_to(x, y)
      # A Shoes `shape` can begin with a line_to; wx needs a current point.
      @started ? @handle.add_line_to_point(x, y) : move_to(x, y)
      self
    end

    def curve_to(c1x, c1y, c2x, c2y, x, y)
      move_to(c1x, c1y) unless @started
      @handle.add_curve_to_point(c1x, c1y, c2x, c2y, x, y)
      self
    end

    # Clogs' shapes are written against libui's convention: angles measured
    # from the positive x axis, increasing clockwise on screen. wx takes a
    # start and an end angle plus a direction, in the same y-down space, so
    # a positive sweep is wx's "clockwise".
    def arc_to(cx, cy, radius, start_angle, sweep, negative = false)
      sweep = -sweep if negative
      @handle.add_arc(cx, cy, radius, start_angle, start_angle + sweep, sweep.positive?)
      @started = true
      self
    end

    # The arc begins a figure of its own rather than continuing the last one.
    def arc_figure(cx, cy, radius, start_angle, sweep, negative = false)
      move_to(cx + radius * Math.cos(start_angle), cy + radius * Math.sin(start_angle))
      arc_to(cx, cy, radius, start_angle, sweep, negative)
    end

    def rect(x, y, w, h)
      @handle.add_rectangle(x, y, w, h)
      @started = true
      self
    end

    def oval(x, y, w, h)
      @handle.add_ellipse(x, y, w, h)
      @started = true
      self
    end

    def close
      @handle.close_subpath if @started
      self
    end

    def end!
      self
    end

    def free
      @live = false
      @handle = nil
    end
  end

  # An immediate-mode drawing surface over a wxGraphicsContext.
  #
  # This is the shortest of the three painters, because wx's graphics context
  # is the same Cairo that libui draws through, reached through an object that
  # already has a transform stack, gradient brushes, path fill rules and an
  # alpha channel. Almost every method here is one call.
  #
  # The one piece of bookkeeping it keeps for itself is the clip rectangle, in
  # device coordinates, so that `visible?` can reject offscreen drawables
  # without asking wx -- the same trick the libui painter uses, and worth as
  # much here.
  class Painter
    WINDING = UI::WINDING
    ALTERNATE = UI::ALTERNATE
    UNBOUNDED = [-1e9, -1e9, 2e9, 2e9].freeze
    IDENTITY = [1.0, 0.0, 0.0, 1.0, 0.0, 0.0].freeze

    class << self
      # Held for the life of the process so wx's default renderer is not
      # collected out from under a path built without a context.
      def renderer
        @renderer ||= Wx::GraphicsRenderer.get_default_renderer
      end

      def clear_cache
        @renderer = nil
      end
    end

    attr_reader :gc, :width, :height

    def initialize(gc, width, height)
      @gc = gc
      @width = width
      @height = height
      @ctm = [IDENTITY]
      @clip = [[0, 0, width, height]]
    end

    # ---- transform stack ----------------------------------------------

    def save
      @gc.push_state
      @ctm.push(@ctm.last)
      @clip.push(@clip.last)
      yield self
    ensure
      @gc.pop_state
      @ctm.pop
      @clip.pop
    end

    def translate(x, y)
      return if x.zero? && y.zero?

      @gc.translate(x, y)
      concat([1.0, 0.0, 0.0, 1.0, x.to_f, y.to_f])
    end

    def rotate(degrees, cx = 0, cy = 0)
      rad = degrees * Math::PI / 180.0
      around(cx, cy) do
        @gc.rotate(rad)
        [Math.cos(rad), Math.sin(rad), -Math.sin(rad), Math.cos(rad), 0.0, 0.0]
      end
    end

    def scale(sx, sy, cx = 0, cy = 0)
      around(cx, cy) do
        @gc.scale(sx, sy)
        [sx.to_f, 0.0, 0.0, sy.to_f, 0.0, 0.0]
      end
    end

    # wx has no skew of its own, but it does take an arbitrary matrix.
    def skew(ax, ay, cx = 0, cy = 0)
      tx = Math.tan(ax * Math::PI / 180.0)
      ty = Math.tan(ay * Math::PI / 180.0)
      around(cx, cy) do
        @gc.concat_transform(@gc.create_matrix(1.0, ty, tx, 1.0, 0.0, 0.0))
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

    # wx intersects with the clip already in force and restores it on
    # pop_state, so the tracked rectangle only has to follow along for
    # `visible?`. Under a rotation the device bounding box is used, which errs
    # towards drawing rather than towards clipping something away.
    def clip_rect(x, y, w, h)
      @gc.clip(x, y, w, h)
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

      @gc.set_brush(brush_for(paint, x, y, w, h))
      @gc.set_pen(UI.no_pen)
      @gc.draw_rectangle(x, y, w, h)
    end

    def stroke_rect(x, y, w, h, paint, thickness: 1)
      return if paint.nil?

      @gc.set_brush(UI.no_brush)
      @gc.set_pen(pen_for(paint, thickness))
      @gc.draw_rectangle(x, y, w, h)
    end

    def fill_oval(x, y, w, h, paint)
      return if paint.nil?
      return unless visible?(x, y, w, h)

      @gc.set_brush(brush_for(paint, x, y, w, h))
      @gc.set_pen(UI.no_pen)
      @gc.draw_ellipse(x, y, w, h)
    end

    def stroke_oval(x, y, w, h, paint, thickness: 1)
      return if paint.nil?

      @gc.set_brush(UI.no_brush)
      @gc.set_pen(pen_for(paint, thickness))
      @gc.draw_ellipse(x, y, w, h)
    end

    def line(x1, y1, x2, y2, paint, thickness: 1, cap: UI::CAP_FLAT)
      return if paint.nil?

      @gc.set_pen(pen_for(paint, thickness, cap: cap))
      @gc.stroke_line(x1, y1, x2, y2)
    end

    # The workhorse: build a path in the block, then fill and/or stroke it.
    def draw(fill: nil, stroke: nil, thickness: 1, cap: UI::CAP_FLAT, join: UI::JOIN_MITER,
      dashes: nil, fill_mode: WINDING)
      path = Path.new(fill_mode, @gc)
      yield path
      path.end!
      fill_path(path, fill) if fill
      stroke_path(path, stroke, thickness: thickness, cap: cap, join: join, dashes: dashes) if stroke
    end

    def fill_path(path, paint)
      return if path.nil? || path.ptr.nil? || paint.nil?

      box = path.handle.get_box
      @gc.set_brush(brush_for(paint, box.x, box.y, box.width, box.height))
      @gc.fill_path(path.handle, path.fill_mode)
    end

    def stroke_path(path, paint, thickness: 1, cap: UI::CAP_FLAT, join: UI::JOIN_MITER, dashes: nil)
      return if path.nil? || path.ptr.nil? || paint.nil?

      @gc.set_pen(pen_for(paint, thickness, cap: cap, join: join, dashes: dashes))
      @gc.stroke_path(path.handle)
    end

    def draw_text(layout, x, y)
      layout.render(self, x, y)
    end

    # Bitmaps. wx composites these through Cairo, so unlike the FOX backend the
    # image's own alpha is honoured against whatever is already on the canvas,
    # and unlike the libui backend it is a blit rather than a few thousand
    # rectangles.
    def draw_image(bitmap, x, y, width = nil, height = nil)
      @gc.draw_bitmap(bitmap, x, y, width || bitmap.width, height || bitmap.height)
    end

    private

    def brush_for(paint, x = 0, y = 0, w = 0, h = 0)
      if paint.is_a?(UI::Gradient)
        # Shoes writes `background a..b` for a vertical gradient over the
        # drawable's own box, which is what the stops describe.
        first = paint.stops.first
        last = paint.stops.last
        @gc.create_linear_gradient_brush(
          x, y, x, y + h,
          UI.colour(first[1]), UI.colour(last[1])
        )
      else
        UI.brush(paint.is_a?(UI::Solid) ? paint.rgba : UI.normalize(paint))
      end
    end

    def pen_for(paint, thickness, cap: UI::CAP_FLAT, join: UI::JOIN_MITER, dashes: nil)
      rgba = case paint
      when UI::Gradient then paint.stops.first[1]
      when UI::Solid then paint.rgba
      else UI.normalize(paint)
      end
      UI.pen(rgba, thickness, cap, join, dashes)
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

    # The transform is applied to wx inside the block; the same matrix is
    # folded into the tracked copy so `visible?` stays honest.
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
