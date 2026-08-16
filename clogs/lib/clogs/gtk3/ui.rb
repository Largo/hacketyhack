# frozen_string_literal: true

require "gtk3"

module Clogs
  # The GTK3 backend's stand-in for Clogs::UI.
  #
  # This is the backend with the least to translate. libui already draws
  # through GTK3 and Cairo on Linux -- it is a C wrapper over this -- so the
  # names below line up with the libui backend's almost exactly, and Clogs'
  # drawing model needs nothing invented.
  module UI
    WINDING = Cairo::FILL_RULE_WINDING
    ALTERNATE = Cairo::FILL_RULE_EVEN_ODD

    CAP_FLAT = Cairo::LINE_CAP_BUTT
    CAP_ROUND = Cairo::LINE_CAP_ROUND
    CAP_SQUARE = Cairo::LINE_CAP_SQUARE
    JOIN_MITER = Cairo::LINE_JOIN_MITER
    JOIN_ROUND = Cairo::LINE_JOIN_ROUND
    JOIN_BEVEL = Cairo::LINE_JOIN_BEVEL

    MOD_CTRL = 1 << 0
    MOD_ALT = 1 << 1
    MOD_SHIFT = 1 << 2
    MOD_SUPER = 1 << 3

    BRUSH_SOLID = 0
    BRUSH_LINEAR_GRADIENT = 1
    BRUSH_RADIAL_GRADIENT = 2

    Solid = Struct.new(:rgba) do
      def type
        BRUSH_SOLID
      end
    end

    # `background red..blue`. Cairo has a real gradient pattern; the stops are
    # carried until the painter knows the box to run them across.
    Gradient = Struct.new(:kind, :from, :to, :stops) do
      def type
        kind
      end
    end

    class << self
      def solid_brush(color)
        Solid.new(normalize(color))
      end

      def gradient_brush(kind, from, to, stops)
        Gradient.new(kind, from, to, stops.map { |pos, color| [pos.to_f, normalize(color)] })
      end

      def normalize(color)
        return [0, 0, 0, 255] unless color

        r, g, b, a = color
        [r.to_i, g.to_i, b.to_i, (a || 255).to_i]
      end

      # Cairo takes its colours as 0..1 floats, with real alpha.
      def rgba(color)
        r, g, b, a = normalize(color)
        [r.clamp(0, 255) / 255.0, g.clamp(0, 255) / 255.0,
         b.clamp(0, 255) / 255.0, a.clamp(0, 255) / 255.0]
      end
    end
  end
end
