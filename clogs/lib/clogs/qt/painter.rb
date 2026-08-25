# frozen_string_literal: true

require_relative "ui"

module Clogs
  # A path under construction.
  #
  # This one is a flat array of doubles rather than a live object: the shim
  # rebuilds it as a QPainterPath in one call. Crossing into C once per shape
  # instead of once per point is what keeps a path-heavy frame -- a Shoes
  # program is nothing else -- from spending its time in Fiddle.
  #
  #   0 x y                  move to
  #   1 x y                  line to
  #   2 c1x c1y c2x c2y x y  cubic to
  #   3 cx cy r start sweep  arc, in Clogs' clockwise-from-+x radians
  #   4 x y w h              rectangle
  #   5 x y w h              ellipse
  #   6                      close
  class Path
    attr_reader :fill_mode, :data

    def initialize(fill_mode = UI::WINDING)
      @fill_mode = fill_mode
      @data = []
      @live = true
    end

    # Image keeps paths across frames on the libui backend and checks this
    # before drawing one.
    def ptr
      @live ? self : nil
    end

    def move_to(x, y)
      @data.push(0.0, x.to_f, y.to_f)
      self
    end

    def line_to(x, y)
      @data.push(1.0, x.to_f, y.to_f)
      self
    end

    def curve_to(c1x, c1y, c2x, c2y, x, y)
      @data.push(2.0, c1x.to_f, c1y.to_f, c2x.to_f, c2y.to_f, x.to_f, y.to_f)
      self
    end

    def arc_to(cx, cy, radius, start_angle, sweep, negative = false)
      @data.push(3.0, cx.to_f, cy.to_f, radius.to_f, start_angle.to_f,
        (negative ? -sweep : sweep).to_f)
      self
    end

    # An arc that opens a figure rather than continuing the last one. Qt has
    # only arcTo, which always connects from the current point, so the shim is
    # told which of the two this is.
    def arc_figure(cx, cy, radius, start_angle, sweep, negative = false)
      @data.push(7.0, cx.to_f, cy.to_f, radius.to_f, start_angle.to_f,
        (negative ? -sweep : sweep).to_f)
      self
    end

    def rect(x, y, w, h)
      @data.push(4.0, x.to_f, y.to_f, w.to_f, h.to_f)
      self
    end

    def oval(x, y, w, h)
      @data.push(5.0, x.to_f, y.to_f, w.to_f, h.to_f)
      self
    end

    def close
      @data.push(6.0)
      self
    end

    def end!
      self
    end

    def empty?
      @data.empty?
    end

    def packed
      @packed ||= @data.pack("d*")
    end

    def free
      @live = false
      @data = []
      @packed = nil
    end
  end

  # An immediate-mode drawing surface over a QPainter.
  #
  # Qt has everything Shoes' drawing model wants -- a transform stack, path
  # fill rules, gradient brushes, real alpha and antialiasing -- so like the wx
  # painter this is mostly one call per method. The bookkeeping it does keep is
  # the device-space clip rectangle, so `visible?` can reject an offscreen
  # drawable without crossing into C at all.
  class Painter
    WINDING = UI::WINDING
    ALTERNATE = UI::ALTERNATE
    IDENTITY = [1.0, 0.0, 0.0, 1.0, 0.0, 0.0].freeze

    attr_reader :handle, :width, :height

    def initialize(handle, width, height)
      @handle = handle
      @width = width
      @height = height
      @ctm = [IDENTITY]
      @clip = [[0, 0, width, height]]
    end

    # ---- transform stack ----------------------------------------------

    def save
      Shim.save(@handle)
      @ctm.push(@ctm.last)
      @clip.push(@clip.last)
      yield self
    ensure
      Shim.restore(@handle)
      @ctm.pop
      @clip.pop
    end

    def translate(x, y)
      return if x.zero? && y.zero?

      Shim.translate(@handle, x.to_f, y.to_f)
      concat([1.0, 0.0, 0.0, 1.0, x.to_f, y.to_f])
    end

    def rotate(degrees, cx = 0, cy = 0)
      rad = degrees * Math::PI / 180.0
      around(cx, cy) do
        Shim.rotate(@handle, degrees.to_f)
        [Math.cos(rad), Math.sin(rad), -Math.sin(rad), Math.cos(rad), 0.0, 0.0]
      end
    end

    def scale(sx, sy, cx = 0, cy = 0)
      around(cx, cy) do
        Shim.scale(@handle, sx.to_f, sy.to_f)
        [sx.to_f, 0.0, 0.0, sy.to_f, 0.0, 0.0]
      end
    end

    def skew(ax, ay, cx = 0, cy = 0)
      tx = Math.tan(ax * Math::PI / 180.0)
      ty = Math.tan(ay * Math::PI / 180.0)
      around(cx, cy) do
        Shim.shear(@handle, tx, ty)
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

    # Qt intersects with the clip already in force and restores it on restore,
    # so the tracked rectangle only follows along for `visible?`.
    def clip_rect(x, y, w, h)
      Shim.clip_rect(@handle, x.to_f, y.to_f, w.to_f, h.to_f)
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

      if paint.is_a?(UI::Gradient)
        draw(fill: paint) { |p| p.rect(x, y, w, h) }
      else
        Shim.fill_rect(@handle, x.to_f, y.to_f, w.to_f, h.to_f, UI.packed(solid(paint)))
      end
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
    def draw(fill: nil, stroke: nil, thickness: 1, cap: UI::CAP_FLAT, join: UI::JOIN_MITER,
      dashes: nil, fill_mode: WINDING)
      path = Path.new(fill_mode)
      yield path
      path.end!
      fill_path(path, fill) if fill
      stroke_path(path, stroke, thickness: thickness, cap: cap, join: join, dashes: dashes) if stroke
    end

    def fill_path(path, paint)
      return if path.nil? || path.ptr.nil? || paint.nil? || path.empty?

      if paint.is_a?(UI::Gradient)
        x0, y0, x1, y1 = path_bounds(path)
        Shim.fill_path_gradient(
          @handle, path.packed, path.data.length, path.fill_mode,
          x0, y0, x0, y1, UI.packed(paint.stops.first[1]), UI.packed(paint.stops.last[1])
        )
        _ = x1
      else
        Shim.fill_path(@handle, path.packed, path.data.length, UI.packed(solid(paint)), path.fill_mode)
      end
    end

    def stroke_path(path, paint, thickness: 1, cap: UI::CAP_FLAT, join: UI::JOIN_MITER, dashes: nil)
      return if path.nil? || path.ptr.nil? || paint.nil? || path.empty?

      packed_dashes = dashes && !dashes.empty? ? dashes.map(&:to_f).pack("d*") : nil
      Shim.stroke_path(
        @handle, path.packed, path.data.length, UI.packed(solid(paint)),
        thickness.to_f, cap, join, packed_dashes, packed_dashes ? dashes.length : 0
      )
    end

    def draw_text(layout, x, y)
      layout.render(self, x, y)
    end

    def draw_image(image, x, y, width, height)
      Shim.draw_image(@handle, image, x.to_f, y.to_f, width.to_f, height.to_f)
    end

    private

    def solid(paint)
      case paint
      when UI::Solid then paint.rgba
      when UI::Gradient then paint.stops.first[1]
      else UI.normalize(paint)
      end
    end

    # Only the vertical extent is needed: `background a..b` in Shoes runs its
    # gradient down the drawable's own box.
    def path_bounds(path)
      xs = []
      ys = []
      d = path.data
      i = 0
      while i < d.length
        case d[i].to_i
        when 0, 1 then xs << d[i + 1]; ys << d[i + 2]; i += 3
        when 2
          xs.push(d[i + 1], d[i + 3], d[i + 5])
          ys.push(d[i + 2], d[i + 4], d[i + 6])
          i += 7
        when 3, 7
          xs.push(d[i + 1] - d[i + 3], d[i + 1] + d[i + 3])
          ys.push(d[i + 2] - d[i + 3], d[i + 2] + d[i + 3])
          i += 6
        when 4, 5
          xs.push(d[i + 1], d[i + 1] + d[i + 3])
          ys.push(d[i + 2], d[i + 2] + d[i + 4])
          i += 5
        else i += 1
        end
      end
      return [0.0, 0.0, 0.0, 0.0] if xs.empty?

      [xs.min, ys.min, xs.max, ys.max]
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
