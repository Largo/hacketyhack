# frozen_string_literal: true

module Clogs
  # The wasm backend's stand-in for Clogs::UI.
  #
  # There is no native library underneath this one. The constants below are
  # the values the command buffer carries to the page, so they are chosen to
  # be what the canvas 2D context wants -- indices into the small tables in
  # web/host.js -- rather than being borrowed from a C header.
  module UI
    # Canvas 2D takes its fill rule as a string; 0 and 1 index CanvasFillRule.
    WINDING = 0
    ALTERNATE = 1

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

    # `background red..blue`. The stops are carried until the painter knows
    # the box to run them across, exactly as on the gtk3 backend.
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

      # The command buffer carries colours as four numbers, so unlike the
      # native backends there is no brush object to build -- the page turns
      # these into an `rgba()` string once per state change.
      def rgba(color)
        r, g, b, a = normalize(color)
        [r.clamp(0, 255), g.clamp(0, 255), b.clamp(0, 255), a.clamp(0, 255)]
      end
    end
  end
end
