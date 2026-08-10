# frozen_string_literal: true

require_relative "../drawable"
require_relative "../paragraph"

module Clogs
  # Shoes' widgets, drawn by hand.
  #
  # libui does have real native buttons and entries, but it can only stack them
  # in boxes and grids -- there is no container that puts a control at an
  # arbitrary (x, y). Shoes' whole layout model needs exactly that, so Clogs
  # paints its widgets into the same area as everything else. The trade-off is
  # noted in docs/libui_shoes_coverage.md: these look like Shoes widgets, not
  # like the host platform's.
  class Control < Drawable
    PADDING_X = 10
    PADDING_Y = 6

    attr_accessor :hovered, :pressed, :focused

    def clickable?
      true
    end

    def text_style(size: nil, color: [0, 0, 0, 255])
      Paragraph::TextStyle.new(
        family: style(:family) || Clogs.default_font_family,
        size: size || (style(:size) || style(:font_size) || Clogs.default_font_size).to_i,
        bold: false, italic: false, underline: false,
        color: color, bg: nil, owner: self
      )
    end

    def label
      style(:text).to_s
    end

    def on_mouse_enter
      self.hovered = true
      redraw!
    end

    def on_mouse_leave
      self.hovered = false
      self.pressed = false
      redraw!
    end
  end

  class Button < Control
    def measure(available_width, available_height = nil)
      st = text_style
      tw, th = Paragraph.measure(label.empty? ? " " : label, st)
      @text_width = tw
      @text_height = th
      @width = requested_width(available_width) || (tw + PADDING_X * 2).ceil
      @height = requested_height(available_height) ||
        (th + PADDING_Y * 2 + style(:padding_top).to_i + style(:padding_bottom).to_i).ceil
    end

    FACE = [246, 246, 246, 255].freeze
    FACE_HOVER = [252, 252, 252, 255].freeze
    FACE_PRESSED = [225, 225, 225, 255].freeze
    EDGE = [160, 160, 160, 255].freeze

    def draw(painter, x, y)
      face = Style.color(style(:color), nil) ||
        (pressed ? FACE_PRESSED : (hovered ? FACE_HOVER : FACE))
      painter.draw(fill: face, stroke: EDGE, thickness: 1) do |p|
        Clogs.rounded_rect(p, x + 0.5, y + 0.5, @width - 1, @height - 1, 4)
      end
      st = text_style(color: Style.color(style(:text_color), [0, 0, 0, 255]))
      block = TextBlock.new(
        [Run.new(text: label, size: st.size, family: st.family, color: st.color)],
        -1, default_family: st.family, default_size: st.size
      )
      block.draw(painter, x + (@width - @text_width) / 2.0, y + (@height - @text_height) / 2.0)
      block.free
    end

    def on_click(_x, _y, _button)
      self.pressed = true
      redraw!
    end

    def on_release(x, y, _button)
      was_pressed = pressed
      self.pressed = false
      redraw!
      notify("click") if was_pressed && contains?(x, y)
    end
  end

  class Check < Control
    BOX = 16

    def measure(_available_width, _available_height = nil)
      @width = BOX
      @height = BOX
    end

    def draw(painter, x, y)
      painter.draw(fill: [255, 255, 255, 255], stroke: [120, 120, 120, 255], thickness: 1) do |p|
        Clogs.rounded_rect(p, x + 0.5, y + 0.5, BOX - 1, BOX - 1, 3)
      end
      return unless style(:checked)

      painter.draw(stroke: [30, 30, 30, 255], thickness: 2, cap: UI::CAP_ROUND) do |p|
        p.move_to(x + 4, y + 8).line_to(x + 7, y + 11).line_to(x + 12, y + 5)
      end
    end

    def on_release(x, y, _button)
      return unless contains?(x, y)

      @styles["checked"] = !style(:checked)
      notify("click")
      redraw!
    end
  end

  class Radio < Control
    BOX = 16

    def measure(_available_width, _available_height = nil)
      @width = BOX
      @height = BOX
    end

    def draw(painter, x, y)
      painter.fill_oval(x, y, BOX, BOX, [255, 255, 255, 255])
      painter.stroke_oval(x + 0.5, y + 0.5, BOX - 1, BOX - 1, [120, 120, 120, 255], thickness: 1)
      return unless style(:checked)

      painter.fill_oval(x + 4, y + 4, BOX - 8, BOX - 8, [30, 30, 30, 255])
    end

    def on_release(x, y, _button)
      return unless contains?(x, y)

      # Selecting one radio in a group clears the others, as Shoes does.
      group = style(:group)
      if group && @parent
        @parent.children.each do |sib|
          sib.styles["checked"] = false if sib.is_a?(Radio) && sib.style(:group) == group
        end
      end
      @styles["checked"] = true
      notify("click")
      redraw!
    end
  end

  class Progress < Control
    def measure(available_width, available_height = nil)
      @width = requested_width(available_width) || [available_width, 200].min
      @height = requested_height(available_height) || 14
    end

    def draw(painter, x, y)
      painter.draw(fill: [235, 235, 235, 255], stroke: [180, 180, 180, 255], thickness: 1) do |p|
        Clogs.rounded_rect(p, x + 0.5, y + 0.5, @width - 1, @height - 1, @height / 2.0)
      end
      fraction = style(:fraction).to_f.clamp(0.0, 1.0)
      return if fraction.zero?

      painter.draw(fill: [60, 140, 230, 255]) do |p|
        Clogs.rounded_rect(p, x + 1, y + 1, (@width - 2) * fraction, @height - 2, (@height - 2) / 2.0)
      end
    end

    def clickable?
      false
    end
  end

  # Shared single/multi-line text editing.
  #
  # This is a deliberately small editor: caret, selection, the usual navigation
  # keys, and clipboard via {Clogs::Clipboard}. libui offers no way to embed its
  # own entry widget in an area, so there is nothing to delegate to.
  module Editable
    attr_reader :caret, :anchor

    def editable_init
      @caret = text_value.length
      @anchor = nil
      @scroll_x = 0
      @scroll_y = 0
    end

    def text_value
      style(:text).to_s
    end

    def text_value=(new_text)
      @styles["text"] = new_text
      notify("change", new_text)
    end

    def focusable?
      true
    end

    def focus_gained
      redraw!
    end

    def focus_lost
      @anchor = nil
      redraw!
    end

    def selection_range
      return nil if @anchor.nil? || @anchor == @caret

      [[@anchor, @caret].min, [@anchor, @caret].max]
    end

    def delete_selection
      range = selection_range
      return false unless range

      from, to = range
      self.text_value = text_value.dup.tap { |t| t[from...to] = "" }
      @caret = from
      @anchor = nil
      true
    end

    def insert(str)
      delete_selection
      t = text_value.dup
      t.insert(@caret, str)
      self.text_value = t
      @caret += str.length
    end

    def on_key(event)
      return false if event.up

      if event.ctrl?
        return handle_ctrl(event)
      end

      case event.ext
      when :left then move_caret(@caret - 1, event.shift?)
      when :right then move_caret(@caret + 1, event.shift?)
      when :home then move_caret(line_start(@caret), event.shift?)
      when :end then move_caret(line_end(@caret), event.shift?)
      when :up then move_caret(caret_line_offset(-1), event.shift?)
      when :down then move_caret(caret_line_offset(1), event.shift?)
      when :delete
        unless delete_selection
          t = text_value.dup
          t[@caret] = "" if @caret < t.length
          self.text_value = t
        end
      else
        return handle_char(event)
      end
      redraw!
      true
    end

    def handle_char(event)
      char = event.char
      return false unless char

      case char
      when "\b", "\x7F"
        unless delete_selection
          if @caret.positive?
            t = text_value.dup
            t[@caret - 1] = ""
            self.text_value = t
            @caret -= 1
          end
        end
      when "\r", "\n"
        return false unless multiline?

        insert("\n")
      when "\t"
        return false
      else
        return false if char.ord < 32

        insert(char)
      end
      redraw!
      true
    end

    def handle_ctrl(event)
      case event.char
      when "a", "\x01"
        @anchor = 0
        @caret = text_value.length
      when "c", "\x03"
        range = selection_range
        Clipboard.write(text_value[range[0]...range[1]]) if range
      when "x", "\x18"
        range = selection_range
        if range
          Clipboard.write(text_value[range[0]...range[1]])
          delete_selection
        end
      when "v", "\x16"
        text = Clipboard.read
        insert(text) if text && !text.empty?
      else
        return false
      end
      redraw!
      true
    end

    def move_caret(pos, extend_selection)
      @anchor = @caret if extend_selection && @anchor.nil?
      @anchor = nil unless extend_selection
      @caret = pos.clamp(0, text_value.length)
    end

    def line_start(pos)
      (text_value.rindex("\n", [pos - 1, 0].max) || -1) + 1
    end

    def line_end(pos)
      text_value.index("\n", pos) || text_value.length
    end

    def caret_line_offset(direction)
      return @caret unless multiline?

      column = @caret - line_start(@caret)
      if direction.negative?
        prev_end = line_start(@caret) - 1
        return @caret if prev_end.negative?

        prev_start = line_start(prev_end)
        [prev_start + column, prev_end].min
      else
        next_start = line_end(@caret) + 1
        return @caret if next_start > text_value.length

        [next_start + column, line_end(next_start)].min
      end
    end

    def multiline?
      false
    end
  end

  class EditLine < Control
    include Editable

    def initialize(properties)
      super
      editable_init
    end

    def displayed_text
      style(:secret) ? "•" * text_value.length : text_value
    end

    def measure(available_width, available_height = nil)
      @width = requested_width(available_width) || [available_width, 200].min
      st = text_style
      @line_height = Paragraph.line_height(st)
      @height = requested_height(available_height) || (@line_height + PADDING_Y * 2).ceil
    end

    def draw(painter, x, y)
      painter.draw(fill: [255, 255, 255, 255], stroke: focused ? [60, 140, 230, 255] : [160, 160, 160, 255],
        thickness: focused ? 2 : 1) do |p|
        Clogs.rounded_rect(p, x + 0.5, y + 0.5, @width - 1, @height - 1, 3)
      end

      st = text_style(color: Style.color(style(:stroke), [0, 0, 0, 255]))
      text = displayed_text
      inner_x = x + 6
      inner_y = y + (@height - @line_height) / 2.0

      painter.save do |p|
        p.clip_rect(x + 2, y + 2, @width - 4, @height - 4)
        if (range = selection_range)
          sx = Paragraph.measure(text[0...range[0]], st)[0]
          sw = Paragraph.measure(text[range[0]...range[1]], st)[0]
          p.fill_rect(inner_x + sx - @scroll_x, inner_y, sw, @line_height, [180, 210, 255, 255])
        end
        unless text.empty?
          block = TextBlock.new([Run.new(text: text, size: st.size, family: st.family, color: st.color)],
            -1, default_family: st.family, default_size: st.size)
          block.draw(p, inner_x - @scroll_x, inner_y)
          block.free
        end
        if focused
          cx = inner_x + Paragraph.measure(text[0...@caret], st)[0] - @scroll_x
          p.line(cx, inner_y, cx, inner_y + @line_height, [0, 0, 0, 255], thickness: 1)
        end
      end
    end

    def on_click(x, y, _button)
      st = text_style
      local = x - @abs_x - 6 + @scroll_x
      @caret = index_for_offset(displayed_text, local, st)
      @anchor = nil
      _ = y
      redraw!
    end

    # Walk the string until the measured prefix passes the click point.
    def index_for_offset(text, offset, st)
      return 0 if offset <= 0

      (0..text.length).each do |i|
        return [i - 1, 0].max if Paragraph.measure(text[0...i], st)[0] > offset
      end
      text.length
    end
  end

  class EditBox < Control
    include Editable

    def initialize(properties)
      super
      editable_init
    end

    def multiline?
      true
    end

    def measure(available_width, available_height = nil)
      @width = requested_width(available_width) || [available_width, 300].min
      st = text_style
      @line_height = Paragraph.line_height(st)
      @height = requested_height(available_height) || (@line_height * 6 + PADDING_Y * 2).ceil
      @paragraph = Paragraph.new([[text_value.empty? ? " " : text_value, st]], @width - 12)
    end

    def draw(painter, x, y)
      painter.draw(fill: [255, 255, 255, 255], stroke: focused ? [60, 140, 230, 255] : [160, 160, 160, 255],
        thickness: focused ? 2 : 1) do |p|
        Clogs.rounded_rect(p, x + 0.5, y + 0.5, @width - 1, @height - 1, 3)
      end
      painter.save do |p|
        p.clip_rect(x + 2, y + 2, @width - 4, @height - 4)
        @paragraph.draw(p, x + 6, y + 4 - @scroll_y)
        draw_caret(p, x, y) if focused
      end
    end

    def draw_caret(painter, x, y)
      item = @paragraph.placed.find { |i| @caret >= i.char_offset && @caret <= i.char_offset + i.text.length }
      return unless item

      st = item.style
      prefix = item.text[0...(@caret - item.char_offset)]
      cx = x + 6 + item.x + Paragraph.measure(prefix, st)[0]
      cy = y + 4 + item.y - @scroll_y
      painter.line(cx, cy, cx, cy + item.height, [0, 0, 0, 255], thickness: 1)
    end

    def on_click(x, y, _button)
      @caret = (@paragraph&.index_at(x - @abs_x - 6, y - @abs_y - 4 + @scroll_y) || 0)
        .clamp(0, text_value.length)
      @anchor = nil
      redraw!
    end
  end

  # A drop-down list. libui's combobox is a real native control, but it cannot
  # live inside an area, so the popup is drawn as an overlay on the same canvas.
  class ListBox < Control
    ROW_HEIGHT = 22

    def items
      Array(style(:items)).map(&:to_s)
    end

    def chosen
      style(:chosen) || items.first
    end

    def measure(available_width, available_height = nil)
      @width = requested_width(available_width) || [available_width, 200].min
      @height = requested_height(available_height) || (Clogs.default_font_size + PADDING_Y * 2).ceil
    end

    def draw(painter, x, y)
      painter.draw(fill: [255, 255, 255, 255], stroke: [160, 160, 160, 255], thickness: 1) do |p|
        Clogs.rounded_rect(p, x + 0.5, y + 0.5, @width - 1, @height - 1, 3)
      end
      st = text_style
      unless chosen.to_s.empty?
        block = TextBlock.new([Run.new(text: chosen.to_s, size: st.size, family: st.family, color: st.color)],
          -1, default_family: st.family, default_size: st.size)
        block.draw(painter, x + 6, y + PADDING_Y / 2.0)
        block.free
      end
      # Arrow
      painter.draw(fill: [80, 80, 80, 255]) do |p|
        ax = x + @width - 16
        ay = y + @height / 2.0 - 2
        p.move_to(ax, ay).line_to(ax + 8, ay).line_to(ax + 4, ay + 5).close
      end
    end

    # Drawn by the app after everything else so it sits on top.
    def draw_overlay(painter)
      return unless @open

      x = @abs_x
      y = @abs_y + @height
      h = ROW_HEIGHT * items.size
      painter.draw(fill: [255, 255, 255, 255], stroke: [140, 140, 140, 255], thickness: 1) do |p|
        p.rect(x + 0.5, y + 0.5, @width - 1, h)
      end
      st = text_style
      items.each_with_index do |item, i|
        iy = y + i * ROW_HEIGHT
        painter.fill_rect(x + 1, iy + 1, @width - 2, ROW_HEIGHT - 1, [220, 235, 255, 255]) if item == chosen
        block = TextBlock.new([Run.new(text: item, size: st.size, family: st.family, color: st.color)],
          -1, default_family: st.family, default_size: st.size)
        block.draw(painter, x + 6, iy + 3)
        block.free
      end
    end

    def open?
      @open
    end

    def overlay_contains?(px, py)
      return false unless @open

      py >= @abs_y + @height && py < @abs_y + @height + ROW_HEIGHT * items.size &&
        px >= @abs_x && px < @abs_x + @width
    end

    def on_click(x, y, _button)
      if @open && overlay_contains?(x, y)
        index = ((y - (@abs_y + @height)) / ROW_HEIGHT).to_i
        item = items[index]
        if item
          @styles["chosen"] = item
          notify("change", item)
        end
        @open = false
      else
        @open = !@open
      end
      redraw!
    end

    def close
      return unless @open

      @open = false
      redraw!
    end
  end
end
