# frozen_string_literal: true

require "fox16"

module Clogs
  # The FOX backend's stand-in for Clogs::UI.
  #
  # The libui backend keeps its FFI bindings and its enumerations in one
  # module, and the rest of Clogs reaches into it for a handful of constants
  # (`UI::CAP_ROUND` in the controls, `UI::MOD_CTRL` in the app, the brush
  # constructors in `Background`). Those names are part of Clogs' internal
  # vocabulary rather than anything libui-specific, so the FOX backend keeps
  # them and supplies its own values.
  module UI
    # Fill rules, named as libui names them.
    WINDING = 0
    ALTERNATE = 1

    # Stroke caps and joins. The values are FOX's own, so a painter can hand
    # them straight to an FXDC.
    CAP_FLAT = Fox::CAP_BUTT
    CAP_ROUND = Fox::CAP_ROUND
    CAP_SQUARE = Fox::CAP_PROJECTING
    JOIN_MITER = Fox::JOIN_MITER
    JOIN_ROUND = Fox::JOIN_ROUND
    JOIN_BEVEL = Fox::JOIN_BEVEL

    # Keyboard modifiers, as bits, matching the libui backend's numbering so
    # that App's `event.modifiers.anybits?(UI::MOD_CTRL)` tests are unchanged.
    MOD_CTRL = 1 << 0
    MOD_ALT = 1 << 1
    MOD_SHIFT = 1 << 2
    MOD_SUPER = 1 << 3

    BRUSH_SOLID = 0
    BRUSH_LINEAR_GRADIENT = 1
    BRUSH_RADIAL_GRADIENT = 2

    # A solid colour, as Shoes hands it over: [r, g, b, a], 0-255.
    #
    # FOX draws through Xlib, which has no notion of a source alpha, so the
    # painter composites translucent paint against its backdrop itself. The
    # colour is carried around unresolved until then.
    Solid = Struct.new(:rgba) do
      def type
        BRUSH_SOLID
      end
    end

    # `background red..blue`. FOX has no gradient fill either, so the painter
    # draws one band per row; keeping the stops here means the geometry is
    # decided where the clip rectangle is known.
    Gradient = Struct.new(:kind, :from, :to, :stops) do
      def type
        kind
      end

      # The colour at 0.0..1.0 along the gradient, interpolated between
      # whichever pair of stops surrounds it.
      def color_at(t)
        t = t.clamp(0.0, 1.0)
        lower = stops.select { |pos, _| pos <= t }.max_by(&:first) || stops.first
        upper = stops.select { |pos, _| pos >= t }.min_by(&:first) || stops.last
        return lower[1].dup if lower[0] == upper[0]

        span = (t - lower[0]) / (upper[0] - lower[0])
        lower[1].each_with_index.map do |channel, i|
          (channel + (upper[1][i] - channel) * span).round
        end
      end
    end

    class << self
      def solid_brush(color)
        Solid.new(normalize(color))
      end

      def gradient_brush(kind, from, to, stops)
        Gradient.new(kind, from, to, stops.map { |pos, color| [pos.to_f, normalize(color)] })
      end

      # Shoes colours arrive as three or four channels; everything downstream
      # wants four.
      def normalize(color)
        return [0, 0, 0, 255] unless color

        r, g, b, a = color
        [r.to_i, g.to_i, b.to_i, (a || 255).to_i]
      end
    end
  end
end
