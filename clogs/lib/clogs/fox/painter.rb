# frozen_string_literal: true

require_relative "ui"

module Clogs
  # A path under construction, in user coordinates.
  #
  # The libui backend hands each path straight to libui, which owns the
  # geometry and the transform. FOX's device context has neither: `FXDC` draws
  # polygons in device pixels and has no matrix stack at all. So a path here is
  # a plain Ruby list of sub-paths, kept in the coordinates it was built in,
  # and the painter transforms it on the way to the screen. That is also what
  # makes a path reusable across frames under different transforms.
  class Path
    # Beziers and arcs are flattened to line segments; these are the segment
    # counts. Curves in a Shoes program are small enough on screen that more
    # than this is invisible.
    BEZIER_STEPS = 16
    ARC_STEP = Math::PI / 16

    attr_reader :fill_mode, :subpaths

    def initialize(fill_mode = UI::WINDING)
      @fill_mode = fill_mode
      @subpaths = []
      @current = nil
      @ended = false
      @live = true
    end

    # Image reuses prebuilt paths and checks this before drawing; the libui
    # backend exposes the underlying pointer, so the check is `ptr.nil?`.
    def ptr
      @live ? self : nil
    end

    def move_to(x, y)
      @current = { points: [[x.to_f, y.to_f]], closed: false, rect: nil }
      @subpaths << @current
      self
    end

    def line_to(x, y)
      move_to(x, y) unless @current
      @current[:points] << [x.to_f, y.to_f]
      @current[:rect] = nil
      self
    end

    def curve_to(c1x, c1y, c2x, c2y, x, y)
      move_to(c1x, c1y) unless @current
      x0, y0 = @current[:points].last
      1.upto(BEZIER_STEPS) do |i|
        t = i.to_f / BEZIER_STEPS
        u = 1.0 - t
        line_to(
          u * u * u * x0 + 3 * u * u * t * c1x + 3 * u * t * t * c2x + t * t * t * x,
          u * u * u * y0 + 3 * u * u * t * c1y + 3 * u * t * t * c2y + t * t * t * y
        )
      end
      self
    end

    # Angles follow the libui convention Clogs' shapes are written against:
    # measured from the positive x axis, increasing clockwise on screen, with
    # a point at (cx + r cos t, cy + r sin t).
    def arc_points(cx, cy, radius, start_angle, sweep, negative)
      sweep = -sweep if negative
      steps = [(sweep.abs / ARC_STEP).ceil, 2].max
      (0..steps).map do |i|
        t = start_angle + sweep * i / steps.to_f
        [cx + radius * Math.cos(t), cy + radius * Math.sin(t)]
      end
    end

    # A line from the current point to the arc's start, then the arc.
    def arc_to(cx, cy, radius, start_angle, sweep, negative = false)
      points = arc_points(cx, cy, radius, start_angle, sweep, negative)
      if @current
        points.each { |px, py| line_to(px, py) }
      else
        move_to(*points.first)
        points.drop(1).each { |px, py| line_to(px, py) }
      end
      self
    end

    # The arc begins a figure of its own.
    def arc_figure(cx, cy, radius, start_angle, sweep, negative = false)
      points = arc_points(cx, cy, radius, start_angle, sweep, negative)
      move_to(*points.first)
      points.drop(1).each { |px, py| line_to(px, py) }
      self
    end

    # Rectangles are tagged as such: an untransformed (or merely translated)
    # rectangle can go to FOX as a rectangle rather than a four-point polygon,
    # which is both faster and free of the off-by-one that polygon rasterising
    # gives axis-aligned edges.
    def rect(x, y, w, h)
      x = x.to_f
      y = y.to_f
      w = w.to_f
      h = h.to_f
      @current = {
        points: [[x, y], [x + w, y], [x + w, y + h], [x, y + h]],
        closed: true,
        rect: [x, y, w, h]
      }
      @subpaths << @current
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
      @current[:closed] = true if @current
      self
    end

    def end!
      @ended = true
      self
    end

    def empty?
      @subpaths.empty?
    end

    # Nothing is allocated outside the Ruby heap, so freeing is bookkeeping
    # only -- but Image calls it, and `ptr` has to start answering nil.
    def free
      @live = false
      @subpaths = []
      @current = nil
    end
  end

  # An immediate-mode drawing surface over an FXDC.
  #
  # This is the FOX half of Clogs' painter contract, and it has to make up for
  # two things FOX's device context does not have: a transform stack and
  # gradients. Both are done here in Ruby -- points are transformed before they
  # are handed over, and a gradient is painted as one band per row, clipped to
  # the shape being filled.
  #
  # What cannot be made up for is alpha. Xlib has no source alpha, so a
  # translucent colour is composited against a known backdrop colour rather
  # than against whatever was actually painted underneath it.
  class Painter
    WINDING = UI::WINDING
    ALTERNATE = UI::ALTERNATE
    UNBOUNDED = [-1e9, -1e9, 2e9, 2e9].freeze
    IDENTITY = [1.0, 0.0, 0.0, 1.0, 0.0, 0.0].freeze

    attr_reader :dc, :width, :height, :backdrop

    def initialize(dc, width, height, backdrop: [255, 255, 255, 255])
      @dc = dc
      @width = width
      @height = height
      @backdrop = backdrop
      @ctm = [IDENTITY]
      # Device-space clip rectangles, tracked so `visible?` can answer without
      # asking FOX and so nested clips intersect rather than replace.
      @clip = [[0, 0, width, height]]
      apply_clip
    end

    # ---- transform stack ----------------------------------------------

    def save
      @ctm.push(@ctm.last)
      @clip.push(@clip.last)
      yield self
    ensure
      @ctm.pop
      @clip.pop
      apply_clip
    end

    def translate(x, y)
      return if x.zero? && y.zero?

      concat([1.0, 0.0, 0.0, 1.0, x.to_f, y.to_f])
    end

    def rotate(degrees, cx = 0, cy = 0)
      rad = degrees * Math::PI / 180.0
      cos = Math.cos(rad)
      sin = Math.sin(rad)
      around(cx, cy) { [cos, sin, -sin, cos, 0.0, 0.0] }
    end

    def scale(sx, sy, cx = 0, cy = 0)
      around(cx, cy) { [sx.to_f, 0.0, 0.0, sy.to_f, 0.0, 0.0] }
    end

    def skew(ax, ay, cx = 0, cy = 0)
      tx = Math.tan(ax * Math::PI / 180.0)
      ty = Math.tan(ay * Math::PI / 180.0)
      around(cx, cy) { [1.0, ty, tx, 1.0, 0.0, 0.0] }
    end

    # True when the transform is a translation and/or an axis-aligned scale,
    # which is the case that can use FOX's rectangle and arc primitives.
    def axis_aligned?
      m = @ctm.last
      m[1].zero? && m[2].zero?
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

    # FOX clips to a rectangle or to a region, never to a path, and a rotated
    # rectangle is not one. Its device bounding box is used instead: a clip
    # that is too generous shows a little more than Shoes would, which is far
    # less wrong than one that is too tight.
    def clip_rect(x, y, w, h)
      x0, y0, x1, y1 = device_bounds(x, y, w, h)
      cx, cy, cw, ch = @clip.last
      nx0 = [x0, cx].max
      ny0 = [y0, cy].max
      nx1 = [x1, cx + cw].min
      ny1 = [y1, cy + ch].min
      @clip[-1] = [nx0, ny0, [nx1 - nx0, 0].max, [ny1 - ny0, 0].max]
      apply_clip
    end

    # ---- fills and strokes ---------------------------------------------

    def fill_rect(x, y, w, h, paint)
      return if w <= 0 || h <= 0 || paint.nil?
      return unless visible?(x, y, w, h)

      if axis_aligned? && !paint.is_a?(UI::Gradient)
        x0, y0, x1, y1 = device_bounds(x, y, w, h)
        set_color(paint)
        @dc.fillRectangle(x0.round, y0.round, (x1 - x0).round, (y1 - y0).round)
      else
        draw(fill: paint) { |p| p.rect(x, y, w, h) }
      end
    end

    def stroke_rect(x, y, w, h, paint, thickness: 1)
      draw(stroke: paint, thickness: thickness) { |p| p.rect(x, y, w, h) }
    end

    def fill_oval(x, y, w, h, paint)
      return if paint.nil?
      return unless visible?(x, y, w, h)

      if axis_aligned? && !paint.is_a?(UI::Gradient)
        x0, y0, x1, y1 = device_bounds(x, y, w, h)
        set_color(paint)
        @dc.fillArc(x0.round, y0.round, (x1 - x0).round, (y1 - y0).round, 0, 360 * 64)
      else
        draw(fill: paint) { |p| p.oval(x, y, w, h) }
      end
    end

    def stroke_oval(x, y, w, h, paint, thickness: 1)
      return if paint.nil?

      if axis_aligned? && thickness <= 1 && !paint.is_a?(UI::Gradient)
        x0, y0, x1, y1 = device_bounds(x, y, w, h)
        set_color(paint)
        @dc.drawArc(x0.round, y0.round, (x1 - x0).round, (y1 - y0).round, 0, 360 * 64)
      else
        draw(stroke: paint, thickness: thickness) { |p| p.oval(x, y, w, h) }
      end
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

      polys = path.subpaths.map { |sub| device_points(sub) }
      if paint.is_a?(UI::Gradient)
        fill_gradient(polys, paint)
      else
        set_color(paint)
        path.subpaths.each_with_index { |sub, i| fill_one(sub, polys[i], path.fill_mode) }
      end
    end

    def stroke_path(path, paint, thickness: 1, cap: UI::CAP_FLAT, join: UI::JOIN_MITER, dashes: nil)
      return if path.nil? || path.ptr.nil? || paint.nil? || path.empty?

      set_color(paint.is_a?(UI::Gradient) ? UI.solid_brush(paint.color_at(0.5)) : paint)
      @dc.lineWidth = [thickness.round, 0].max
      @dc.lineCap = cap
      @dc.lineJoin = join
      if dashes && !dashes.empty?
        @dc.lineStyle = Fox::LINE_ONOFF_DASH
        @dc.setDashes(0, dashes.map { |d| [d.round, 1].max })
      else
        @dc.lineStyle = Fox::LINE_SOLID
      end

      path.subpaths.each_with_index do |sub, i|
        points = device_points(sub)
        points = points + [points.first] if sub[:closed] && points.size > 2
        next if points.size < 2

        @dc.drawLines(points.map { |px, py| Fox::FXPoint.new(px.round, py.round) })
      end
      @dc.lineStyle = Fox::LINE_SOLID
    end

    # Text is laid out and measured by the TextBlock; the painter only has to
    # place it. FOX cannot rotate or shear a font, so a transform contributes
    # its translation and any scale it carries, and a rotation is dropped.
    def draw_text(layout, x, y)
      dx, dy = apply(x, y)
      layout.render(self, dx, dy)
    end

    # Bitmaps go straight to the X server. This is the call the libui backend
    # has no equivalent for, and the reason it paints images as rectangles.
    def draw_image(image, x, y)
      dx, dy = apply(x, y)
      @dc.drawImage(image, dx.round, dy.round)
    end

    def draw_icon(icon, x, y)
      dx, dy = apply(x, y)
      @dc.drawIcon(icon, dx.round, dy.round)
    end

    # Composite an [r, g, b, a] colour against the painter's backdrop and hand
    # FOX the opaque result.
    def resolve(rgba)
      r, g, b, a = rgba
      a ||= 255
      return nil if a.zero?

      if a < 255
        br, bg, bb = @backdrop
        t = a / 255.0
        r = (r * t + br * (1 - t)).round
        g = (g * t + bg * (1 - t)).round
        b = (b * t + bb * (1 - t)).round
      end
      Fox.FXRGB(r.clamp(0, 255), g.clamp(0, 255), b.clamp(0, 255))
    end

    private

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

    def device_points(sub)
      sub[:points].map { |px, py| apply(px, py) }
    end

    # The device-space bounding box of a user-space rectangle.
    def device_bounds(x, y, w, h)
      corners = [[x, y], [x + w, y], [x + w, y + h], [x, y + h]].map { |px, py| apply(px, py) }
      xs = corners.map(&:first)
      ys = corners.map(&:last)
      [xs.min, ys.min, xs.max, ys.max]
    end

    def apply_clip
      x, y, w, h = @clip.last
      @dc.setClipRectangle(x.round, y.round, [w.round, 0].max, [h.round, 0].max)
    end

    def set_color(paint)
      rgba = paint.is_a?(UI::Solid) ? paint.rgba : UI.normalize(paint)
      color = resolve(rgba)
      @dc.foreground = color if color
      !color.nil?
    end

    def fill_one(sub, points, fill_mode)
      if sub[:rect] && axis_aligned?
        x0 = points.map(&:first).min
        y0 = points.map(&:last).min
        x1 = points.map(&:first).max
        y1 = points.map(&:last).max
        @dc.fillRectangle(x0.round, y0.round, (x1 - x0).round, (y1 - y0).round)
      elsif points.size >= 3
        @dc.fillRule = fill_mode == ALTERNATE ? Fox::RULE_EVEN_ODD : Fox::RULE_WINDING
        @dc.fillComplexPolygon(points.map { |px, py| Fox::FXPoint.new(px.round, py.round) })
      end
    end

    # FOX has no gradient brush. Clip to the shape, then paint one row-high
    # rectangle per step along the gradient axis. A 400px gradient costs about
    # a fifth of a millisecond, which is cheaper than the bitmap path the libui
    # backend needs for an ordinary image.
    def fill_gradient(polys, gradient)
      points = polys.flatten(1)
      return if points.empty?

      x0 = points.map(&:first).min.floor
      y0 = points.map(&:last).min.floor
      x1 = points.map(&:first).max.ceil
      y1 = points.map(&:last).max.ceil
      return if x1 <= x0 || y1 <= y0

      # The gradient's own axis is in user space; only its vertical extent is
      # used, which is what `background a..b` means in Shoes.
      with_region(polys) do
        (y0...y1).each do |y|
          color = resolve(gradient.color_at((y - y0).to_f / [y1 - y0 - 1, 1].max))
          next unless color

          @dc.foreground = color
          @dc.fillRectangle(x0, y, x1 - x0, 1)
        end
      end
    end

    # Restrict drawing to the union of some polygons, then put the clip back.
    def with_region(polys)
      shaped = polys.select { |pts| pts.size >= 3 }
      if shaped.empty?
        yield
        return
      end

      region = shaped.map { |pts| Fox::FXRegion.new(pts.map { |px, py| Fox::FXPoint.new(px.round, py.round) }, false) }
        .reduce { |acc, r| acc + r }
      cx, cy, cw, ch = @clip.last
      region = region * Fox::FXRegion.new(cx.round, cy.round, [cw.round, 0].max, [ch.round, 0].max)
      @dc.setClipRegion(region)
      yield
    ensure
      apply_clip
    end
  end
end
