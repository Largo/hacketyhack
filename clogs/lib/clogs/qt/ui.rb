# frozen_string_literal: true

require_relative "shim"

module Clogs
  # The Qt backend's stand-in for Clogs::UI: the enumerations the rest of Clogs
  # reaches for, and the two brush constructors `Background` uses.
  module UI
    WINDING = 0
    ALTERNATE = 1

    # Cap and join values as the shim reads them.
    CAP_FLAT = 0
    CAP_ROUND = 1
    CAP_SQUARE = 2
    JOIN_MITER = 0
    JOIN_ROUND = 1
    JOIN_BEVEL = 2

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

    # `background red..blue`. Qt has a real gradient brush; the stops are
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

      # The shim takes colours as one packed 0xRRGGBBAA word, which keeps a
      # fill to a single argument rather than four.
      def packed(color)
        r, g, b, a = normalize(color)
        ((r.clamp(0, 255) << 24) | (g.clamp(0, 255) << 16) | (b.clamp(0, 255) << 8) | a.clamp(0, 255))
      end
    end
  end
end
