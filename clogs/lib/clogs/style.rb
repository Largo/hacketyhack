# frozen_string_literal: true

module Clogs
  # Coercion of Shoes style values into the numbers and colours the painter
  # wants. Shoes is famously relaxed about types: a width can be `100`, `0.5`,
  # `"50%"` or `-20`, and a colour can be a symbol, a string, an array or a
  # Shoes::Color.
  module Style
    module_function

    # Resolve a Shoes dimension against the space available.
    #
    #   100    => 100 pixels
    #   0.5    => half of `available`
    #   "50%"  => half of `available`
    #   -20    => `available` minus 20
    #   nil    => nil (meaning "size yourself")
    def dimension(value, available)
      case value
      when nil then nil
      when Integer
        value.negative? ? [available + value, 0].max : value
      when Float
        value <= 1.0 && value >= -1.0 ? (available * value).round : value.round
      when String
        if value.end_with?("%")
          (available * value.to_f / 100.0).round
        else
          value.to_i
        end
      else
        value.respond_to?(:to_i) ? value.to_i : nil
      end
    end

    # Shoes colours reach the display service as [r, g, b, a] arrays, but user
    # code can also set a bare symbol or "#ff0000" that never went through
    # Shoes::Colors.
    def color(value, default = nil)
      case value
      when nil then default
      when Array
        r, g, b, a = value
        [r.to_i, g.to_i, b.to_i, (a || 255).to_i]
      when String
        if value.start_with?("#")
          hex(value)
        else
          named(value) || default
        end
      when Symbol
        named(value.to_s) || default
      else
        if value.respond_to?(:to_a)
          color(value.to_a, default)
        else
          default
        end
      end
    end

    def hex(str)
      s = str.delete_prefix("#")
      s = s.chars.map { |c| c * 2 }.join if s.length == 3
      alpha = s[6, 2]
      [s[0, 2].to_i(16), s[2, 2].to_i(16), s[4, 2].to_i(16),
       alpha.nil? || alpha.empty? ? 255 : alpha.to_i(16)]
    end

    def named(name)
      require "shoes/colors" if !defined?(Shoes::Colors)
      rgb = Shoes::Colors.to_rgb(name.to_sym)
      rgb.is_a?(Array) ? color(rgb) : nil
    rescue StandardError
      nil
    end

    # Shoes lets a margin be one number or [left, top, right, bottom].
    def margins(styles)
      m = styles["margin"] || styles[:margin]
      base = case m
      when nil then [0, 0, 0, 0]
      when Array then m.map(&:to_i)
      when Numeric then [m.to_i] * 4
      when String then [m.to_i] * 4
      else [0, 0, 0, 0]
      end
      left, top, right, bottom = base
      [
        (styles["margin_left"] || left).to_i,
        (styles["margin_top"] || top).to_i,
        (styles["margin_right"] || right).to_i,
        (styles["margin_bottom"] || bottom).to_i
      ]
    end

    def paddings(styles)
      p = styles["padding"] || styles[:padding]
      base = case p
      when nil then [0, 0, 0, 0]
      when Array then p.map(&:to_i)
      when Numeric then [p.to_i] * 4
      else [0, 0, 0, 0]
      end
      left, top, right, bottom = base
      [
        (styles["padding_left"] || left).to_i,
        (styles["padding_top"] || top).to_i,
        (styles["padding_right"] || right).to_i,
        (styles["padding_bottom"] || bottom).to_i
      ]
    end
  end
end
