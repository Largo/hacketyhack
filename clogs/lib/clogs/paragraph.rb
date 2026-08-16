# frozen_string_literal: true

# Whichever backend's TextBlock is in play; clogs.rb loads it. This is libui's.
require_relative "text" if Clogs.libui?

module Clogs
  # Word-level text layout.
  #
  # libui will happily wrap a whole attributed string for us, but it will not
  # tell us *where* it put anything -- there is no hit-testing or caret API on
  # uiDrawTextLayout. Shoes needs that geometry: links have to be clickable,
  # `para#hit` has to map a pixel to a character, and the editor has to draw a
  # caret.
  #
  # So Clogs does its own line breaking. Each run is split into words, each
  # word is measured once and cached, and lines are filled greedily. Drawing
  # then batches adjacent words that share a style back into a single layout,
  # so the common case still costs one libui text layout per line per style.
  class Paragraph
    # Shoes' named sizes, matching Scarpe's.
    SIZES = {
      inscription: 10, ins: 10, para: 12, caption: 14,
      tagline: 18, subtitle: 26, title: 34, banner: 48
    }.freeze

    Placed = Struct.new(:text, :style, :x, :y, :width, :height, :owner, :char_offset)

    attr_reader :width, :height, :lines, :placed

    class << self
      # Cache of [style_key, text] => [width, height]. Text-heavy apps repeat
      # the same words constantly, and each miss costs an attributed string,
      # a text layout and two FFI calls.
      def measure_cache
        @measure_cache ||= {}
      end

      def measure(text, style)
        return [0.0, line_height(style)] if text.empty?

        key = [style.cache_key, text].freeze
        measure_cache[key] ||= begin
          block = TextBlock.new(
            [Run.new(text: text, size: style.size, family: style.family,
              bold: style.bold, italic: style.italic, color: style.color)],
            -1,
            default_family: style.family,
            default_size: style.size
          )
          dims = [block.width, block.height]
          block.free
          dims
        end
      end

      def line_height(style)
        key = [style.cache_key, :__line_height].freeze
        measure_cache[key] ||= begin
          w, h = measure("Hg", style)
          _ = w
          [0.0, h]
        end
        measure_cache[key][1]
      end
    end

    # An immutable text style. Runs with equal styles can be drawn together.
    TextStyle = Struct.new(:family, :size, :bold, :italic, :underline, :strike, :color, :bg, :owner,
      keyword_init: true) do
      def cache_key
        @cache_key ||= [family, size, bold, italic].freeze
      end

      def with(**changes)
        TextStyle.new(to_h.merge(changes))
      end

      def same_run_as?(other)
        family == other.family && size == other.size && bold == other.bold &&
          italic == other.italic && underline == other.underline && strike == other.strike &&
          color == other.color
      end
    end

    # @param runs [Array<Array(String, TextStyle)>] text and its style
    # @param wrap_width [Numeric] width to wrap at
    def initialize(runs, wrap_width, align: :left)
      @runs = runs
      @wrap_width = wrap_width.to_f
      @align = align
      layout
    end

    # Split into words while keeping the whitespace attached to the preceding
    # word, so that trailing spaces do not start a new line on their own.
    def self.tokenize(text)
      text.scan(/\n|[^\s]+[ \t]*|[ \t]+/)
    end

    def layout
      @placed = []
      x = 0.0
      y = 0.0
      line_start = 0
      line_height = 0.0
      char_offset = 0
      max_x = 0.0
      # Where the line's last visible glyph ends, as opposed to where the pen
      # ends up. A wrapped line keeps the space that followed its final word,
      # and measuring to there reports a paragraph wider than the width it was
      # asked to wrap at -- by however wide a space is in the font, which
      # differs between display backends. The wrap decision below already
      # ignores that space; so should the width.
      line_ink = 0.0

      flush_line = lambda do
        align_line(line_start, x, line_height)
        max_x = [max_x, line_ink].max
        y += line_height.positive? ? line_height : 0
        x = 0.0
        line_ink = 0.0
        line_height = 0.0
        line_start = @placed.size
      end

      @runs.each do |text, style|
        self.class.tokenize(text.to_s).each do |token|
          if token == "\n"
            line_height = self.class.line_height(style) if line_height.zero?
            char_offset += 1
            flush_line.call
            next
          end

          w, h = self.class.measure(token, style)
          # Trailing spaces should not force a wrap.
          stripped = token.rstrip
          effective_w = stripped == token ? w : self.class.measure(stripped, style)[0]

          if x.positive? && @wrap_width.positive? && x + effective_w > @wrap_width
            flush_line.call
          end

          @placed << Placed.new(token, style, x, y, w, h, style.owner, char_offset)
          char_offset += token.length
          line_ink = x + effective_w
          x += w
          line_height = [line_height, h].max
        end
      end
      flush_line.call

      @width = max_x
      @height = y
    end

    def align_line(from, line_width, _line_height)
      return if @align == :left || @wrap_width <= 0

      shift = case @align
      when :center then (@wrap_width - line_width) / 2.0
      when :right then @wrap_width - line_width
      else 0.0
      end
      return if shift <= 0

      (from...@placed.size).each { |i| @placed[i].x += shift }
    end

    # Draw, batching runs that share a line and a style.
    def draw(painter, ox, oy)
      batch = []
      flush = lambda do
        next if batch.empty?

        first = batch.first
        text = batch.map(&:text).join
        style = first.style
        block = TextBlock.new(
          [Run.new(text: text, size: style.size, family: style.family, bold: style.bold,
            italic: style.italic, underline: style.underline, strike: style.strike,
            color: style.color)],
          -1,
          default_family: style.family,
          default_size: style.size
        )
        if style.bg
          h = batch.map(&:height).max
          w = batch.sum(&:width)
          painter.fill_rect(ox + first.x, oy + first.y, w, h, style.bg)
        end
        block.draw(painter, ox + first.x, oy + first.y)
        block.free
        batch = []
      end

      @placed.each do |item|
        prev = batch.last
        if prev && (prev.y != item.y || !prev.style.same_run_as?(item.style) ||
            prev.style.bg != item.style.bg)
          flush.call
        end
        batch << item
      end
      flush.call
    end

    # Bounding boxes for everything contributed by `owner`, used to make links
    # clickable. One box per line the owner appears on.
    def boxes_for(owner)
      items = @placed.select { |i| i.owner.equal?(owner) }
      items.group_by(&:y).map do |y, line_items|
        x0 = line_items.map(&:x).min
        x1 = line_items.map { |i| i.x + i.width }.max
        h = line_items.map(&:height).max
        [x0, y, x1 - x0, h]
      end
    end

    # The y of the line containing a character index, for caret scrolling.
    def line_top(char_index)
      return 0 if @placed.empty?

      item = @placed.find { |i| char_index < i.char_offset + i.text.length } || @placed.last
      item.y
    end

    # Character index nearest to a point, for text selection.
    def index_at(px, py)
      line = @placed.select { |i| py >= i.y && py < i.y + i.height }
      line = @placed if line.empty?
      return 0 if line.empty?

      item = line.find { |i| px < i.x + i.width } || line.last
      frac = item.width.zero? ? 0 : (px - item.x) / item.width
      item.char_offset + (frac * item.text.length).round.clamp(0, item.text.length)
    end
  end
end
