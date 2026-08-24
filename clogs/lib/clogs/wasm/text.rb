# frozen_string_literal: true

require_relative "ui"
require_relative "bridge"

module Clogs
  # One styled run of text inside a paragraph.
  Run = Struct.new(:text, :size, :color, :family, :bold, :italic, :underline, :strike, :owner,
    keyword_init: true) do
    def style_key
      [size, color, family, bold, italic, underline, strike]
    end
  end

  # Text, measured by the canvas that will draw it.
  #
  # `measureText` is the only text API a canvas has, and it is exactly enough:
  # a width and, since the font metrics were added to TextMetrics, an ascent
  # and a descent. Clogs does its own word layout anyway -- that is shared code
  # on every backend -- so a wrapping text engine was never what was needed.
  #
  # What matters here is the caching. A measurement is a call out of wasm and
  # into JS, which costs on the order of ten microseconds, and a frame of
  # Hackety Hack measures the same handful of words hundreds of times. Both
  # the metrics and the CSS font strings are memoised, so a steady-state frame
  # makes no measurement calls at all.
  module Fonts
    # Shoes' family names, as the native backends resolve them, mapped onto
    # what CSS calls the same thing. Anything else is passed through as a
    # family name with a generic fallback behind it.
    GENERIC = {
      "sans" => "sans-serif", "sans-serif" => "sans-serif", "arial" => "Arial, sans-serif",
      "helvetica" => "Helvetica, sans-serif", "segoe ui" => "'Segoe UI', sans-serif",
      "serif" => "serif", "times" => "'Times New Roman', serif",
      "times new roman" => "'Times New Roman', serif", "georgia" => "Georgia, serif",
      "monospace" => "monospace", "mono" => "monospace", "courier" => "'Courier New', monospace",
      "courier new" => "'Courier New', monospace", "consolas" => "Consolas, monospace",
      "monaco" => "Monaco, monospace"
    }.freeze

    class << self
      def clear
        @metrics = nil
        @fonts = nil
        @families = nil
      end

      def metrics_cache
        @metrics ||= {}
      end

      # A CSS font shorthand: "italic bold 14px sans-serif".
      def font_string(family, size, bold, italic)
        key = [family, size, bold, italic]
        (@fonts ||= {})[key] ||= begin
          parts = []
          parts << "italic" if italic
          parts << "bold" if bold
          parts << "#{(size || Clogs.default_font_size).to_f.round(2)}px"
          parts << css_family(family || Clogs.default_font_family)
          parts.join(" ")
        end
      end

      def css_family(family)
        name = family.to_s
        (@families ||= {})[name] ||= GENERIC[name.downcase] ||
          (name.include?(",") ? name : "'#{name.gsub("'", "")}', sans-serif")
      end

      def font_for(run, default_family, default_size)
        font_string(run&.family || default_family, run&.size || default_size,
          run&.bold ? true : false, run&.italic ? true : false)
      end

      # [width, ascent, descent] for one string in one font.
      def metrics(text, font)
        key = [text, font]
        metrics_cache[key] ||= Wasm::Bridge.measure_text(text, font)
      end

      # The [width, height] pair the shared layout code works in. Height is
      # the font's own ascent plus descent rather than the glyphs' -- the
      # line box, not the ink -- which is what Pango's logical extent gives
      # the other backends.
      def extent(text, run, default_family, default_size)
        w, a, d = metrics(text.to_s, font_for(run, default_family, default_size))
        [w, a + d]
      end
    end
  end

  # A laid-out run of text.
  class TextBlock
    ALIGN_LEFT = 0
    ALIGN_CENTER = 1
    ALIGN_RIGHT = 2

    Piece = Struct.new(:text, :run, :font, :x, :y, :width, :height, :ascent)

    attr_reader :width, :height, :runs

    def initialize(runs, wrap_width, align: ALIGN_LEFT, default_family: nil, default_size: nil)
      @runs = runs
      @wrap_width = wrap_width.to_f
      @align = align
      @default_family = default_family || Clogs.default_font_family
      @default_size = default_size || Clogs.default_font_size
      build
    end

    def draw(painter, x, y)
      painter.draw_text(self, x, y)
    end

    # Clogs works in top-left corners and a canvas draws text from a baseline,
    # so each piece carries the ascent it was measured with.
    def render(painter, ox, oy)
      @pieces.each do |piece|
        color = piece.run.color || [0, 0, 0, 255]
        painter.fill_text(piece.text, piece.font, color, ox + piece.x, oy + piece.y + piece.ascent)
        next unless piece.run.underline || piece.run.strike

        # Neither is a font property, and a canvas draws neither for you.
        thickness = [(piece.height / 14.0).round, 1].max
        if piece.run.underline
          under = oy + piece.y + piece.ascent + thickness
          painter.line(ox + piece.x, under, ox + piece.x + piece.width, under, color, thickness: thickness)
        end
        if piece.run.strike
          mid = oy + piece.y + piece.ascent - piece.ascent / 3.0
          painter.line(ox + piece.x, mid, ox + piece.x + piece.width, mid, color, thickness: thickness)
        end
      end
    end

    # Width of the first `n` characters, used to place text carets.
    def prefix_width(n)
      return 0.0 if n <= 0

      text = plain_text
      n = text.length if n > text.length
      @prefix_cache ||= {}
      @prefix_cache[n] ||= Fonts.extent(text[0, n], @runs.first, @default_family, @default_size)[0].to_f
    end

    def plain_text
      @plain_text ||= @runs.map { |r| r.text.to_s }.join
    end

    def free
      @pieces = []
    end

    private

    def build
      @pieces = []
      x = 0.0
      y = 0.0
      line_start = 0
      line_height = 0.0
      max_x = 0.0

      flush = lambda do
        align_line(line_start, x)
        max_x = [max_x, x].max
        y += line_height
        x = 0.0
        line_height = 0.0
        line_start = @pieces.size
      end

      @runs.each do |run|
        text = run.text.to_s
        next if text.empty?

        font = Fonts.font_for(run, @default_family, @default_size)
        tokens = @wrap_width.positive? ? text.scan(/[^\s]+[ \t]*|[ \t]+|\n/) : [text]
        tokens.each do |token|
          if token == "\n"
            line_height = Fonts.metrics("Hg", font).then { |_w, a, d| a + d } if line_height.zero?
            flush.call
            next
          end

          w, ascent, descent = Fonts.metrics(token, font)
          h = ascent + descent
          flush.call if x.positive? && @wrap_width.positive? && x + w > @wrap_width

          @pieces << Piece.new(token, run, font, x, y, w, h, ascent)
          x += w
          line_height = [line_height, h].max
        end
      end
      flush.call

      @width = max_x
      @height = y
    end

    def align_line(from, line_width)
      return if @align == ALIGN_LEFT || @wrap_width <= 0

      shift = @align == ALIGN_CENTER ? (@wrap_width - line_width) / 2.0 : @wrap_width - line_width
      return if shift <= 0

      (from...@pieces.size).each { |i| @pieces[i].x += shift }
    end
  end
end
