# frozen_string_literal: true

require_relative "ui"

module Clogs
  # One styled run of text inside a paragraph.
  Run = Struct.new(:text, :size, :color, :family, :bold, :italic, :underline, :strike, :owner,
    keyword_init: true) do
    def style_key
      [size, color, family, bold, italic, underline, strike]
    end
  end

  # Text measurement.
  #
  # Qt builds a QFont from a description on every call and keeps its own cache
  # of the resolved font behind that, so there is nothing to hold on this side
  # -- unlike FOX and wx, whose font objects are handles that have to be kept
  # (or, on wx, must not be). Measuring needs no window and no paint in
  # progress, which is what lets Clogs lay text out during its own layout pass.
  module Fonts
    class << self
      def clear; end

      def extent(text, family, size, bold: false, italic: false)
        Shim.out_doubles do |w, h|
          Shim.text_extent(text.to_s, (family || Clogs.default_font_family).to_s,
            (size || Clogs.default_font_size).to_f, bold ? 1 : 0, italic ? 1 : 0, w, h)
        end
      end
    end
  end

  # A laid-out run of text.
  #
  # Clogs' Paragraph does its own word layout -- every TextBlock it builds has
  # a wrap width of -1 and holds a single line -- so this measures and places
  # runs. Wrapping is implemented anyway for a caller that asks for it.
  class TextBlock
    ALIGN_LEFT = 0
    ALIGN_CENTER = 1
    ALIGN_RIGHT = 2

    Piece = Struct.new(:text, :run, :x, :y, :width, :height)

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

    # Called back by the painter. The shim takes the top-left corner and does
    # the baseline arithmetic on Qt's side, where the font metrics already are.
    def render(painter, ox, oy)
      @pieces.each do |piece|
        run = piece.run
        Shim.draw_text(
          painter.handle, (ox + piece.x).to_f, (oy + piece.y).to_f, piece.text,
          (run.family || @default_family).to_s, (run.size || @default_size).to_f,
          run.bold ? 1 : 0, run.italic ? 1 : 0, run.underline ? 1 : 0, run.strike ? 1 : 0,
          UI.packed(run.color || [0, 0, 0, 255])
        )
      end
    end

    # Width of the first `n` characters, used to place text carets.
    def prefix_width(n)
      return 0.0 if n <= 0

      text = plain_text
      n = text.length if n > text.length
      @prefix_cache ||= {}
      @prefix_cache[n] ||= measure(text[0, n], @runs.first)[0]
    end

    def plain_text
      @plain_text ||= @runs.map { |r| r.text.to_s }.join
    end

    def free
      @pieces = []
    end

    private

    def measure(text, run)
      Fonts.extent(text, run&.family || @default_family, run&.size || @default_size,
        bold: run&.bold ? true : false, italic: run&.italic ? true : false)
    end

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

        tokens = @wrap_width.positive? ? text.scan(/[^\s]+[ \t]*|[ \t]+|\n/) : [text]
        tokens.each do |token|
          if token == "\n"
            line_height = measure("Hg", run)[1] if line_height.zero?
            flush.call
            next
          end

          w, h = measure(token, run)
          flush.call if x.positive? && @wrap_width.positive? && x + w > @wrap_width

          @pieces << Piece.new(token, run, x, y, w, h)
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
