# frozen_string_literal: true

require_relative "ui"

module Clogs
  # A path under construction. libui aborts the process if a path is ended
  # twice or drawn before being ended, so the state is tracked here rather
  # than left to callers.
  class Path
    attr_reader :ptr

    def initialize(fill_mode)
      @ptr = UI::L.draw_new_path(fill_mode)
      @ended = false
    end

    def move_to(x, y)
      UI::L.draw_path_new_figure(@ptr, x, y)
      self
    end

    def line_to(x, y)
      UI::L.draw_path_line_to(@ptr, x, y)
      self
    end

    def curve_to(c1x, c1y, c2x, c2y, x, y)
      UI::L.draw_path_bezier_to(@ptr, c1x, c1y, c2x, c2y, x, y)
      self
    end

    def arc_to(cx, cy, radius, start_angle, sweep, negative = false)
      UI::L.draw_path_arc_to(@ptr, cx, cy, radius, start_angle, sweep, negative ? 1 : 0)
      self
    end

    def arc_figure(cx, cy, radius, start_angle, sweep, negative = false)
      UI::L.draw_path_new_figure_with_arc(@ptr, cx, cy, radius, start_angle, sweep, negative ? 1 : 0)
      self
    end

    def rect(x, y, w, h)
      UI::L.draw_path_add_rectangle(@ptr, x, y, w, h)
      self
    end

    # Four beziers approximate an ellipse closely enough for UI work and avoid
    # needing a scale matrix per oval (libui arcs are always circular).
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
      UI::L.draw_path_close_figure(@ptr)
      self
    end

    def end!
      return self if @ended

      @ended = true
      UI::L.draw_path_end(@ptr)
      self
    end

    def free
      UI::L.draw_free_path(@ptr) if @ptr
      @ptr = nil
    end
  end

  # An immediate-mode drawing surface over a uiDrawContext.
  #
  # Shoes is a canvas library: everything from a `rect` to a `button` is
  # ultimately painted. libui's draw API is closely modelled on Cairo (paths,
  # brushes, matrices, clipping, save/restore), so the mapping is direct.
  class Painter
    WINDING = UI::WINDING
    ALTERNATE = UI::ALTERNATE

    attr_reader :context, :width, :height

    def initialize(context, width, height)
      @context = context
      @width = width
      @height = height
      # Track the clip rectangle ourselves: painting a bitmap costs one path
      # per run of pixels, so knowing what cannot be visible pays for itself
      # many times over. Transforms make the tracked rect meaningless, so any
      # transform widens it to "everything" for the rest of its scope.
      @clip_bounds = [[0, 0, width, height]]
    end

    UNBOUNDED = [-1e9, -1e9, 2e9, 2e9].freeze

    # True if a rectangle can touch the current clip region at all.
    def visible?(x, y, w, h)
      cx, cy, cw, ch = @clip_bounds.last
      x < cx + cw && x + w > cx && y < cy + ch && y + h > cy
    end

    # libui has no "unclip" and no way to read back the current transform, so
    # every clip or transform must be scoped by save/restore.
    def save
      @clip_bounds.push(@clip_bounds.last)
      UI::L.draw_save(@context)
      yield self
    ensure
      UI::L.draw_restore(@context)
      @clip_bounds.pop
    end

    def translate(x, y)
      return if x.zero? && y.zero?

      @clip_bounds[-1] = UNBOUNDED
      apply_matrix { |m| UI::L.draw_matrix_translate(m, x, y) }
    end

    def rotate(degrees, cx = 0, cy = 0)
      @clip_bounds[-1] = UNBOUNDED
      apply_matrix { |m| UI::L.draw_matrix_rotate(m, cx, cy, degrees * Math::PI / 180.0) }
    end

    def scale(sx, sy, cx = 0, cy = 0)
      @clip_bounds[-1] = UNBOUNDED
      apply_matrix { |m| UI::L.draw_matrix_scale(m, cx, cy, sx, sy) }
    end

    def skew(ax, ay, cx = 0, cy = 0)
      @clip_bounds[-1] = UNBOUNDED
      apply_matrix { |m| UI::L.draw_matrix_skew(m, cx, cy, ax * Math::PI / 180.0, ay * Math::PI / 180.0) }
    end

    def clip_rect(x, y, w, h)
      cx, cy, cw, ch = @clip_bounds.last
      nx1 = [x, cx].max
      ny1 = [y, cy].max
      nx2 = [x + w, cx + cw].min
      ny2 = [y + h, cy + ch].min
      @clip_bounds[-1] = [nx1, ny1, [nx2 - nx1, 0].max, [ny2 - ny1, 0].max]

      p = Path.new(WINDING)
      p.rect(x, y, w, h).end!
      UI::L.draw_clip(@context, p.ptr)
    ensure
      p&.free
    end

    def fill_rect(x, y, w, h, paint)
      return if w <= 0 || h <= 0
      return unless visible?(x, y, w, h)

      draw(fill: paint) { |p| p.rect(x, y, w, h) }
    end

    def stroke_rect(x, y, w, h, paint, thickness: 1)
      draw(stroke: paint, thickness: thickness) { |p| p.rect(x, y, w, h) }
    end

    def fill_oval(x, y, w, h, paint)
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
    def draw(fill: nil, stroke: nil, thickness: 1, cap: UI::CAP_FLAT, join: UI::JOIN_MITER,
      dashes: nil, fill_mode: WINDING)
      p = Path.new(fill_mode)
      yield p
      p.end!
      UI::L.draw_fill(@context, p.ptr, brush_for(fill).to_ptr) if fill
      if stroke
        sp = UI.stroke_params(thickness, cap: cap, join: join, dashes: dashes)
        UI::L.draw_stroke(@context, p.ptr, brush_for(stroke).to_ptr, sp.to_ptr)
      end
    ensure
      p&.free
    end

    def draw_text(layout, x, y)
      UI::L.draw_text(@context, layout, x, y)
    end

    # Fill an already-built, already-ended path. Callers that draw the same
    # geometry every frame (images) keep their paths and brushes alive and
    # skip the whole path-building round trip.
    def fill_path(path, paint)
      UI::L.draw_fill(@context, path.ptr, brush_for(paint).to_ptr)
    end

    private

    def brush_for(paint)
      return paint if paint.respond_to?(:Type)

      UI.solid_brush(paint)
    end

    def apply_matrix
      m = UI.malloc(UI::L::FFI::DrawMatrix)
      UI::L.draw_matrix_set_identity(m)
      yield m
      UI::L.draw_transform(@context, m)
    end
  end
end
