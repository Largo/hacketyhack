# frozen_string_literal: true

require_relative "ui"

module Clogs
  # A path under construction, in user coordinates.
  #
  # draw2d has no path object at all: it draws rectangles, ellipses, polygons
  # and polylines, and that is the whole of it. So a path here is a list of
  # sub-paths built in Ruby, exactly as the FOX backend does it -- but unlike
  # FOX, the points stay in the coordinates they were built in, because draw2d
  # does have a transform and applies it for us.
  #
  # Sub-paths remember whether they were asked for as a rectangle or an
  # ellipse. Those go to draw2d as rectangles and ellipses under the current
  # matrix, which keeps a rotated oval smooth instead of flattening it to the
  # sixty-four points a polygon would need.
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
      @live = true
    end

    # Image keeps paths across frames on the libui backend and checks this
    # before drawing one.
    def ptr
      @live ? self : nil
    end

    def move_to(x, y)
      @current = { kind: :poly, points: [x.to_f, y.to_f], closed: false }
      @subpaths << @current
      self
    end

    def line_to(x, y)
      move_to(x, y) unless @current && @current[:kind] == :poly
      @current[:points].push(x.to_f, y.to_f)
      self
    end

    def curve_to(c1x, c1y, c2x, c2y, x, y)
      move_to(c1x, c1y) unless @current && @current[:kind] == :poly
      points = @current[:points]
      x0 = points[-2]
      y0 = points[-1]
      1.upto(BEZIER_STEPS) do |i|
        t = i.to_f / BEZIER_STEPS
        u = 1.0 - t
        points.push(
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
      (0..steps).flat_map do |i|
        t = start_angle + sweep * i / steps.to_f
        [cx + radius * Math.cos(t), cy + radius * Math.sin(t)]
      end
    end

    # A line from the current point to the arc's start, then the arc.
    def arc_to(cx, cy, radius, start_angle, sweep, negative = false)
      points = arc_points(cx, cy, radius, start_angle, sweep, negative)
      if @current && @current[:kind] == :poly
        @current[:points].concat(points)
      else
        move_to(points[0], points[1])
        @current[:points].concat(points.drop(2))
      end
      self
    end

    # The arc begins a figure of its own.
    def arc_figure(cx, cy, radius, start_angle, sweep, negative = false)
      points = arc_points(cx, cy, radius, start_angle, sweep, negative)
      move_to(points[0], points[1])
      @current[:points].concat(points.drop(2))
      self
    end

    def rect(x, y, w, h)
      @current = { kind: :rect, box: [x.to_f, y.to_f, w.to_f, h.to_f], closed: true }
      @subpaths << @current
      self
    end

    def oval(x, y, w, h)
      @current = { kind: :oval, box: [x.to_f, y.to_f, w.to_f, h.to_f], closed: true }
      @subpaths << @current
      self
    end

    def close
      @current[:closed] = true if @current
      self
    end

    def end!
      self
    end

    def empty?
      @subpaths.empty?
    end

    # Each polygon crosses into C as one packed buffer rather than one call
    # per point, so a path-heavy frame -- a Shoes program is nothing else --
    # does not spend its time in Fiddle.
    def packed(sub)
      sub[:packed] ||= sub[:points].pack("f*")
    end

    # The user-space bounding box, for gradients and for culling.
    def bounds
      xs = []
      ys = []
      @subpaths.each do |sub|
        if sub[:kind] == :poly
          pts = sub[:points]
          i = 0
          while i < pts.length
            xs << pts[i]
            ys << pts[i + 1]
            i += 2
          end
        else
          x, y, w, h = sub[:box]
          xs.push(x, x + w)
          ys.push(y, y + h)
        end
      end
      return [0.0, 0.0, 0.0, 0.0] if xs.empty?

      [xs.min, ys.min, xs.max, ys.max]
    end

    # Nothing is allocated outside the Ruby heap, so freeing is bookkeeping
    # only -- but Image calls it, and `ptr` has to start answering nil.
    def free
      @live = false
      @subpaths = []
      @current = nil
    end
  end

  # An immediate-mode drawing surface over a draw2d DCtx.
  #
  # draw2d is a drawing API rather than a scene graph: it has a transform, real
  # alpha, antialiasing, linear gradients, dashes and joins, and it can blit a
  # bitmap. What it does not have is a path object, and -- alone among the six
  # backends -- any clipping at all: no rectangle, no region, no path.
  #
  # Clogs needs one in three places (a sized slot, an edit line, an edit box),
  # so a clip here is an offscreen bitmap the size of the clip rectangle, drawn
  # into and then blitted back. A bitmap has edges, which is the whole of what
  # a clip rectangle is. It costs an allocation and a blit per clip per frame,
  # which is the price of the feature not being there.
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
      # Device-space clip rectangles, always in the *root* surface's
      # coordinates however many offscreen bitmaps are stacked up, so that
      # `visible?` means one thing throughout.
      @clip = [[0, 0, width, height]]
      # Offscreen surfaces currently being drawn into, innermost last.
      @redirects = []
      # Root-device bounds of the surface being drawn on right now.
      @surface = [0.0, 0.0, width.to_f, height.to_f]
      # Where the current surface's origin sits in root device coordinates.
      @origin_x = 0.0
      @origin_y = 0.0
      @applied = nil
    end

    # ---- transform stack ----------------------------------------------
    #
    # draw2d's transform is one absolute matrix rather than a stack, which
    # suits Clogs: the painter keeps the current matrix in Ruby anyway, so a
    # save/restore is a push and a pop here and the matrix is only pushed to C
    # when something is about to be drawn with it.

    def save
      @ctm.push(@ctm.last)
      @clip.push(@clip.last)
      depth = @redirects.length
      yield self
    ensure
      end_redirect while @redirects.length > depth
      @ctm.pop
      @clip.pop
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

    # Narrow the clip, and redirect drawing into a bitmap that is exactly it.
    #
    # Only the axis-aligned device bounding box is clipped to, which is all
    # Clogs ever asks for: a rotated clip would show a little more than Shoes
    # would, which is far less wrong than showing a little less.
    def clip_rect(x, y, w, h)
      x0, y0, x1, y1 = device_bounds(x, y, w, h)
      cx, cy, cw, ch = @clip.last
      nx0 = [x0, cx].max
      ny0 = [y0, cy].max
      nx1 = [x1, cx + cw].min
      ny1 = [y1, cy + ch].min
      nw = [nx1 - nx0, 0].max
      nh = [ny1 - ny0, 0].max
      @clip[-1] = [nx0, ny0, nw, nh]
      return if nw < 1 || nh < 1
      # A clip that already contains the whole surface cuts nothing off, and
      # the surface has edges of its own. Shoes' root slot is exactly this --
      # it has an explicit size, so every document asks to be clipped to its
      # own window once a frame -- and skipping it is the difference between
      # a bitmap per frame and none.
      return if contains_surface?(nx0, ny0, nw, nh)

      begin_redirect(nx0.floor, ny0.floor, nw.ceil, nh.ceil)
    end

    def contains_surface?(x, y, w, h)
      sx, sy, sw, sh = @surface
      x <= sx && y <= sy && x + w >= sx + sw && y + h >= sy + sh
    end

    # ---- fills and strokes ---------------------------------------------

    def fill_rect(x, y, w, h, paint)
      return if w <= 0 || h <= 0 || paint.nil?
      return unless visible?(x, y, w, h)

      sync_matrix
      set_fill(paint, x, y, w, h)
      Shim.rect(@handle, Shim::OP_FILL, x.to_f, y.to_f, w.to_f, h.to_f)
    end

    def stroke_rect(x, y, w, h, paint, thickness: 1)
      return if paint.nil?
      return unless visible?(x, y, w, h)

      sync_matrix
      set_stroke(paint, thickness, UI::CAP_FLAT, UI::JOIN_MITER, nil)
      Shim.rect(@handle, Shim::OP_STROKE, x.to_f, y.to_f, w.to_f, h.to_f)
    end

    def fill_oval(x, y, w, h, paint)
      return if paint.nil? || w <= 0 || h <= 0
      return unless visible?(x, y, w, h)

      sync_matrix
      set_fill(paint, x, y, w, h)
      Shim.ellipse(@handle, Shim::OP_FILL, x + w / 2.0, y + h / 2.0, w / 2.0, h / 2.0)
    end

    def stroke_oval(x, y, w, h, paint, thickness: 1)
      return if paint.nil? || w <= 0 || h <= 0
      return unless visible?(x, y, w, h)

      sync_matrix
      set_stroke(paint, thickness, UI::CAP_FLAT, UI::JOIN_MITER, nil)
      Shim.ellipse(@handle, Shim::OP_STROKE, x + w / 2.0, y + h / 2.0, w / 2.0, h / 2.0)
    end

    def line(x1, y1, x2, y2, paint, thickness: 1, cap: UI::CAP_FLAT)
      return if paint.nil?

      sync_matrix
      set_stroke(paint, thickness, cap, UI::JOIN_MITER, nil)
      Shim.line(@handle, x1.to_f, y1.to_f, x2.to_f, y2.to_f)
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

      sync_matrix
      x0, y0, x1, y1 = path.bounds
      set_fill(paint, x0, y0, x1 - x0, y1 - y0)
      path.subpaths.each { |sub| draw_sub(path, sub, Shim::OP_FILL) }
    end

    def stroke_path(path, paint, thickness: 1, cap: UI::CAP_FLAT, join: UI::JOIN_MITER, dashes: nil)
      return if path.nil? || path.ptr.nil? || paint.nil? || path.empty?

      sync_matrix
      set_stroke(paint, thickness, cap, join, dashes)
      path.subpaths.each { |sub| draw_sub(path, sub, Shim::OP_STROKE) }
    end

    # Text is laid out and measured by the TextBlock; the painter only places
    # it. draw2d draws text under the current matrix like everything else, so
    # rotated and scaled text needs nothing special here.
    def draw_text(layout, x, y)
      sync_matrix
      layout.render(self, x, y)
    end

    # Bitmaps go straight to the platform's own blit -- this is the call the
    # libui backend has no equivalent for, and the reason it paints images as
    # tens of thousands of rectangles. The image arrives already scaled to the
    # size Shoes asked for, so only the corner is needed.
    def draw_image(image, x, y, _width = nil, _height = nil)
      sync_matrix
      Shim.draw_image(@handle, image, x.to_f, y.to_f)
    end

    def antialias(on)
      Shim.antialias(@handle, on ? 1 : 0)
    end

    private

    # Hand draw2d the current matrix, but only when it has moved since the
    # last shape -- a frame of a Shoes document is mostly drawing under one
    # transform at a time. Everything Clogs computes is in root device
    # coordinates, so an offscreen surface takes its own origin off the
    # translation on the way through.
    def sync_matrix
      m = @ctm.last
      return if @applied.equal?(m)

      Shim.matrix(@handle, m[0], m[1], m[2], m[3], m[4] - @origin_x, m[5] - @origin_y)
      @applied = m
    end

    # Start drawing into a bitmap that stands in for a clip rectangle.
    def begin_redirect(x, y, w, h)
      ctx = Shim.ctx_bitmap(w, h)
      return if ctx.nil? || ctx.null?

      @redirects.push([@handle, ctx, x, y, @origin_x, @origin_y, @surface])
      @handle = ctx
      @origin_x = x.to_f
      @origin_y = y.to_f
      @surface = [x.to_f, y.to_f, w.to_f, h.to_f]
      @applied = nil
    end

    # Finish the innermost one and composite it back where it came from.
    def end_redirect
      parent, ctx, x, y, ox, oy, surface = @redirects.pop
      @handle = parent
      @origin_x = ox
      @origin_y = oy
      @surface = surface
      @applied = nil

      image = Shim.ctx_to_image(ctx)
      return if image.nil? || image.null?

      # The blit is in the parent surface's own coordinates, not the
      # document's, so it goes out under an identity transform.
      Shim.matrix(parent, 1.0, 0.0, 0.0, 1.0, 0.0, 0.0)
      Shim.draw_image(parent, image, (x - ox).to_f, (y - oy).to_f)
      Shim.image_free(image)
    end

    def draw_sub(path, sub, op)
      case sub[:kind]
      when :rect
        x, y, w, h = sub[:box]
        Shim.rect(@handle, op, x, y, w, h)
      when :oval
        x, y, w, h = sub[:box]
        Shim.ellipse(@handle, op, x + w / 2.0, y + h / 2.0, w / 2.0, h / 2.0)
      else
        count = sub[:points].length / 2
        if op == Shim::OP_FILL
          Shim.polygon(@handle, op, path.packed(sub), count) if count >= 3
        elsif count >= 2
          Shim.polyline(@handle, sub[:closed] ? 1 : 0, path.packed(sub), count)
        end
      end
    end

    def solid(paint)
      case paint
      when UI::Solid then paint.rgba
      when UI::Gradient then paint.stops.first[1]
      else UI.normalize(paint)
      end
    end

    # A gradient needs the box it runs across, which is why every caller
    # passes one. `background a..b` in Shoes runs down the drawable's own box.
    def set_fill(paint, x, y, _w, h)
      if paint.is_a?(UI::Gradient)
        Shim.fill_linear(@handle, UI.packed(paint.stops.first[1]), UI.packed(paint.stops.last[1]),
          x.to_f, y.to_f, x.to_f, (y + h).to_f)
      else
        Shim.fill_color(@handle, UI.packed(solid(paint)))
      end
    end

    def set_stroke(paint, thickness, cap, join, dashes)
      packed_dashes = dashes && !dashes.empty? ? dashes.map(&:to_f).pack("f*") : nil
      Shim.line_style(@handle, UI.packed(solid(paint)), thickness.to_f, cap, join,
        packed_dashes, packed_dashes ? dashes.length : 0)
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
