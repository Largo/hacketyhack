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

  # Text measurement, over draw2d's Font.
  #
  # A NAppGUI Font is a handle that has to be kept and destroyed, like FOX's
  # and unlike Qt's, so they are cached by description -- a Shoes document asks
  # for the same handful thousands of times a frame. The cache is also what
  # keeps the underline and strikethrough styles cheap: NAppGUI carries both on
  # the font rather than as text attributes, so a `del()` run is just a
  # different cache key.
  #
  # None of this may happen before the SDK is up (see Shim.started?), so an
  # extent asked for too early answers zero rather than crashing.
  module Fonts
    class << self
      def cache
        @cache ||= {}
      end

      def clear
        cache.each_value { |font| Shim.font_destroy(font) }
        cache.clear
        @extents = nil
      end

      # draw2d wants a literal Pango family name and asserts on anything
      # else, so a fontconfig alias like "Sans" -- what Clogs uses as its
      # cross-backend default, since every *other* backend resolves it via
      # its toolkit's own font description parsing -- has to be turned into
      # one first. `fc-match` does that; its answer only depends on the
      # alias and the machine's installed fonts, so it is cached per family
      # rather than shelled out to on every draw.
      def resolved_family(family)
        (@resolved ||= {}).fetch(family) do
          @resolved[family] = begin
            require "open3"
            out, status = Open3.capture2("fc-match", "-f", "%{family}", family)
            status.success? && !out.strip.empty? ? out.strip : family
          rescue StandardError
            family
          end
        end
      end

      def font_for(family, size, bold, italic, underline, strike)
        key = [family, size, bold, italic, underline, strike]
        cache[key] ||= Shim.font(
          resolved_family((family || Clogs.default_font_family).to_s),
          (size || Clogs.default_font_size).to_f,
          bold ? 1 : 0, italic ? 1 : 0, underline ? 1 : 0, strike ? 1 : 0
        )
      end

      def font_for_run(run, default_family, default_size)
        font_for(run&.family || default_family, run&.size || default_size,
          run&.bold, run&.italic, run&.underline, run&.strike)
      end

      # Measuring crosses into C, and a Shoes document measures the same
      # word over and over as it lays a paragraph out; the result only
      # depends on the string and the font.
      def extent(text, run, default_family, default_size)
        return [0.0, 0.0] unless Shim.started?

        font = font_for_run(run, default_family, default_size)
        key = [text, font.to_i]
        @extents ||= {}
        @extents[key] ||= Shim.out_floats { |w, h| Shim.font_extents(font, text.to_s, w, h) }
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

    Piece = Struct.new(:text, :run, :font, :x, :y, :width, :height)

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

    # draw2d places text by its top-left corner, which is the corner Clogs
    # works in, so there is no baseline arithmetic.
    def render(painter, ox, oy)
      @pieces.each do |piece|
        Shim.draw_text(painter.handle, piece.font, piece.text,
          (ox + piece.x).to_f, (oy + piece.y).to_f,
          UI.packed(piece.run.color || [0, 0, 0, 255]))
      end
    end

    # Width of the first `n` characters, used to place text carets.
    def prefix_width(n)
      return 0.0 if n <= 0

      text = plain_text
      n = text.length if n > text.length
      @prefix_cache ||= {}
      @prefix_cache[n] ||= measure(text[0, n], @runs.first)[0].to_f
    end

    def plain_text
      @plain_text ||= @runs.map { |r| r.text.to_s }.join
    end

    # Fonts belong to the shared cache, so a block owns nothing to free.
    def free
      @pieces = []
    end

    private

    def measure(text, run)
      Fonts.extent(text, run, @default_family, @default_size)
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

        font = Shim.started? ? Fonts.font_for_run(run, @default_family, @default_size) : nil
        tokens = @wrap_width.positive? ? text.scan(/[^\s]+[ \t]*|[ \t]+|\n/) : [text]
        tokens.each do |token|
          if token == "\n"
            line_height = measure("Hg", run)[1] if line_height.zero?
            flush.call
            next
          end

          w, h = measure(token, run)
          flush.call if x.positive? && @wrap_width.positive? && x + w > @wrap_width

          @pieces << Piece.new(token, run, font, x, y, w, h)
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
