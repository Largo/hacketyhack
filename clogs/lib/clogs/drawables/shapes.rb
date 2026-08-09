# frozen_string_literal: true

require_relative "../drawable"

module Clogs
  # A rounded rectangle, built from four quarter-circle arcs.
  def self.rounded_rect(path, x, y, w, h, r)
    r = [r, w / 2.0, h / 2.0].min
    hp = Math::PI / 2
    path.arc_figure(x + r, y + r, r, Math::PI, hp)
    path.arc_to(x + w - r, y + r, r, -hp, hp)
    path.arc_to(x + w - r, y + h - r, r, 0, hp)
    path.arc_to(x + r, y + h - r, r, hp, hp)
    path.close
  end

  # Shoes' art drawables. In Shoes these always carry their own left/top and so
  # are positioned within the current slot rather than flowed.
  class ArtDrawable < Drawable
    def positioned?
      true
    end

    def left
      Style.dimension(style(:left), parent_content_width).to_i
    end

    def top
      Style.dimension(style(:top), parent_content_width).to_i
    end

    def parent_content_width
      @parent.respond_to?(:instance_variable_get) ? (@parent&.instance_variable_get(:@content_width) || 0) : 0
    end

    # Shoes' `fill`, `stroke`, `strokewidth` and `rotate` are *draw context*
    # styles: set once on a slot, inherited by every art drawable made inside
    # it. Lacci copies them onto drawables that declare them as their own
    # styles, but drawables like Line and Shape do not, so the draw context has
    # to be consulted directly.
    def draw_context
      @styles["draw_context"] || {}
    end

    def context_style(name)
      value = style(name)
      value.nil? ? draw_context[name.to_s] : value
    end

    # `nofill` and `nostroke` arrive as fully transparent colours rather than
    # as nil, so treat zero alpha as "do not paint this".
    def fill_paint
      opaque(Style.color(context_style(:fill), nil))
    end

    def stroke_paint
      opaque(Style.color(context_style(:stroke), nil))
    end

    def opaque(color)
      color && color[3].to_i.positive? ? color : nil
    end

    def strokewidth
      (context_style(:strokewidth) || 1).to_i
    end

    def rotation
      context_style(:rotate).to_f
    end

    # Art drawables paint relative to the slot, honouring any rotation from the
    # draw context.
    def paint(painter, ox, oy)
      @abs_x = ox + @x
      @abs_y = oy + @y
      if rotation.zero?
        draw(painter, @abs_x, @abs_y)
      else
        painter.save do |p|
          p.rotate(rotation, @abs_x + @width / 2.0, @abs_y + @height / 2.0)
          draw(p, @abs_x, @abs_y)
        end
      end
    end
  end

  class Rect < ArtDrawable
    def measure(available_width)
      @width = Style.dimension(style(:width), available_width).to_i
      @height = Style.dimension(style(:height), available_width).to_i
    end

    def draw(painter, x, y)
      curve = style(:curve).to_i
      if curve.positive?
        painter.draw(fill: fill_paint, stroke: stroke_paint, thickness: strokewidth) do |p|
          Clogs.rounded_rect(p, x, y, @width, @height, curve)
        end
      else
        painter.fill_rect(x, y, @width, @height, fill_paint) if fill_paint
        painter.stroke_rect(x, y, @width, @height, stroke_paint, thickness: strokewidth) if stroke_paint
      end
    end

  end

  class Oval < ArtDrawable
    def measure(available_width)
      radius = style(:radius)
      if radius && !style(:width)
        @width = @height = radius.to_i * 2
      else
        @width = Style.dimension(style(:width), available_width).to_i
        @height = Style.dimension(style(:height), available_width).to_i
      end
    end

    def draw(painter, x, y)
      # Shoes' `center: true` means left/top name the centre, not the corner.
      if style(:center)
        x -= @width / 2.0
        y -= @height / 2.0
      end
      painter.fill_oval(x, y, @width, @height, fill_paint) if fill_paint
      painter.stroke_oval(x, y, @width, @height, stroke_paint, thickness: strokewidth) if stroke_paint
    end
  end

  class Line < ArtDrawable
    def measure(available_width)
      @x2 = Style.dimension(style(:x2), available_width).to_i
      @y2 = Style.dimension(style(:y2), available_width).to_i
      @width = (@x2 - left).abs
      @height = (@y2 - top).abs
    end

    # A line's endpoints are both slot coordinates, so it cannot use the usual
    # "draw at my top-left" convention.
    def paint(painter, ox, oy)
      @abs_x = ox + [left, @x2].min
      @abs_y = oy + [top, @y2].min
      painter.line(ox + left, oy + top, ox + @x2, oy + @y2,
        stroke_paint || [0, 0, 0, 255], thickness: strokewidth)
    end
  end

  class Star < ArtDrawable
    def points
      (style(:points) || 10).to_i
    end

    def outer
      (style(:outer) || 100).to_f
    end

    def inner
      (style(:inner) || 50).to_f
    end

    def measure(_available_width)
      @width = @height = (outer * 2).round
    end

    def draw(painter, x, y)
      cx = x + outer
      cy = y + outer
      painter.draw(fill: fill_paint, stroke: stroke_paint, thickness: strokewidth) do |p|
        (0...(points * 2)).each do |i|
          r = i.even? ? outer : inner
          angle = -Math::PI / 2 + i * Math::PI / points
          px = cx + r * Math.cos(angle)
          py = cy + r * Math.sin(angle)
          i.zero? ? p.move_to(px, py) : p.line_to(px, py)
        end
        p.close
      end
    end
  end

  class Arc < ArtDrawable
    def measure(available_width)
      @width = Style.dimension(style(:width), available_width).to_i
      @height = Style.dimension(style(:height), available_width).to_i
    end

    def draw(painter, x, y)
      a1 = style(:angle1).to_f
      a2 = style(:angle2).to_f
      sweep = a2 - a1
      radius = [@width, @height].min / 2.0
      cx = x + @width / 2.0
      cy = y + @height / 2.0
      painter.draw(fill: fill_paint, stroke: stroke_paint, thickness: strokewidth) do |p|
        p.move_to(cx, cy) if style(:wedge)
        p.arc_figure(cx, cy, radius, a1, sweep) unless style(:wedge)
        p.arc_to(cx, cy, radius, a1, sweep) if style(:wedge)
        p.close if style(:wedge)
      end
    end
  end

  # `shape { move_to ...; line_to ... }` -- Shoes records the commands and the
  # display service replays them.
  class Shape < ArtDrawable
    def measure(_available_width)
      xs = []
      ys = []
      Array(style(:shape_commands)).each do |cmd|
        _name, *args = cmd
        args.each_slice(2) { |px, py| xs << px.to_f; ys << py.to_f if py }
      end
      @width = xs.empty? ? 0 : xs.max.ceil
      @height = ys.empty? ? 0 : ys.max.ceil
    end

    def draw(painter, x, y)
      painter.draw(fill: fill_paint, stroke: stroke_paint, thickness: strokewidth) do |p|
        started = false
        Array(style(:shape_commands)).each do |cmd|
          name, *args = cmd
          case name.to_s
          when "move_to"
            p.move_to(x + args[0], y + args[1])
            started = true
          when "line_to"
            p.move_to(x + args[0], y + args[1]) unless started
            started = true
            p.line_to(x + args[0], y + args[1])
          when "curve_to"
            p.curve_to(x + args[2], y + args[3], x + args[4], y + args[5], x + args[0], y + args[1])
          when "arc_to"
            p.arc_to(x + args[0], y + args[1], args[2], args[4].to_f, args[5].to_f - args[4].to_f)
          end
        end
      end
    end
  end

  # Background and Border cover the slot that contains them rather than
  # occupying a place in its layout.
  class SlotDecoration < Drawable
    def measure_for_slot(width, height)
      @width = width
      @height = height
    end

    def measure(_available_width); end
  end

  class Background < SlotDecoration
    def paint_for_slot(painter, x, y, w, h)
      @abs_x = x
      @abs_y = y
      @width = w
      @height = h
      paint = background_paint(x, y, w, h)
      return unless paint

      curve = style(:curve).to_i
      if curve.positive?
        painter.draw(fill: paint) { |p| Clogs.rounded_rect(p, x, y, w, h, curve) }
      else
        painter.fill_rect(x, y, w, h, paint)
      end
    end

    # Shoes lets a background be a colour, or a gradient written as
    # `background red..blue`.
    def background_paint(x, y, w, h)
      fill = style(:fill) || style(:color)
      if fill.is_a?(Range) || (fill.is_a?(Array) && fill.length == 2 && fill.first.is_a?(Array))
        from, to = fill.is_a?(Range) ? [fill.first, fill.last] : fill
        UI.gradient_brush(UI::BRUSH_LINEAR_GRADIENT, [x, y], [x, y + h],
          [[0.0, Style.color(from)], [1.0, Style.color(to)]])
      else
        _ = w
        Style.color(fill, nil)
      end
    end
  end

  class Border < SlotDecoration
    def paint_for_slot(painter, x, y, w, h)
      @abs_x = x
      @abs_y = y
      @width = w
      @height = h
      color = Style.color(style(:stroke), [0, 0, 0, 255])
      thickness = (style(:strokewidth) || 1).to_i
      inset = thickness / 2.0
      curve = style(:curve).to_i
      if curve.positive?
        painter.draw(stroke: color, thickness: thickness) do |p|
          Clogs.rounded_rect(p, x + inset, y + inset, w - thickness, h - thickness, curve)
        end
      else
        painter.stroke_rect(x + inset, y + inset, w - thickness, h - thickness, color, thickness: thickness)
      end
    end
  end
end
