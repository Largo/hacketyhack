# frozen_string_literal: true

require_relative "ui"
require_relative "painter"

module Clogs
  # Owns one <canvas> in the page and turns the DOM's events into the same
  # plain Ruby events every other backend produces.
  #
  # Unlike the native backends this one is not handed a callback by a toolkit:
  # a JS->Ruby call is expensive enough that dispatching every mousemove
  # individually would cost more than drawing the frame. The page therefore
  # queues DOM events and hands the whole batch to Runtime.tick once per
  # animation frame, which routes them here. Coalescing motion is not a
  # compromise -- there is no use for two mouse positions in one frame.
  class Canvas
    attr_reader :window_id
    attr_accessor :on_draw, :on_mouse, :on_key, :on_crossed, :on_wheel

    def initialize(window_id, width, height)
      @window_id = window_id
      @width = width
      @height = height
      @dirty = true
    end

    attr_reader :width, :height

    def resize(width, height)
      return if width == @width && height == @height

      @width = width
      @height = height
      @dirty = true
    end

    def redraw
      @dirty = true unless @destroyed
    end

    def dirty?
      @dirty && !@destroyed
    end

    # Draw one frame into a fresh command buffer and hand it to the page.
    def paint
      return unless @on_draw && !@destroyed

      @dirty = false
      painter = Painter.new(@width, @height)
      @on_draw.call(painter, nil)
      Wasm::Bridge.flush(@window_id, painter.ops, painter.strings)
    end

    # A canvas is exactly as big as it is; there is no scrolling viewport
    # under it, so these are the same no-ops the nappgui backend has.
    def set_scroll_size(_w, _h); end

    def scroll_to(_x, _y, _w, _h); end

    def destroy
      @destroyed = true
    end

    MouseEvent = Struct.new(:x, :y, :area_width, :area_height, :down, :up, :count, :modifiers, :held,
      keyword_init: true) do
      def button_down?
        held.anybits?(1)
      end
    end

    KeyEvent = Struct.new(:char, :ext, :modifier, :modifiers, :up, keyword_init: true) do
      def ctrl?
        modifiers.anybits?(UI::MOD_CTRL)
      end

      def shift?
        modifiers.anybits?(UI::MOD_SHIFT)
      end

      def alt?
        modifiers.anybits?(UI::MOD_ALT)
      end
    end

    # KeyboardEvent.key values under the names Clogs' App expects.
    EXT_KEYS = {
      "Escape" => :escape, "Insert" => :insert, "Delete" => :delete,
      "Home" => :home, "End" => :end, "PageUp" => :page_up, "PageDown" => :page_down,
      "ArrowUp" => :up, "ArrowDown" => :down, "ArrowLeft" => :left, "ArrowRight" => :right,
      "F1" => :f1, "F2" => :f2, "F3" => :f3, "F4" => :f4, "F5" => :f5, "F6" => :f6,
      "F7" => :f7, "F8" => :f8, "F9" => :f9, "F10" => :f10, "F11" => :f11, "F12" => :f12
    }.freeze

    # KeyboardEvent.key is already the character the layout produced, so there
    # is no shift table and no US-layout assumption here either.
    CHARS = { "Backspace" => "\b", "Enter" => "\n", "Tab" => "\t", "Spacebar" => " " }.freeze

    def dispatch_mouse(x, y, down, up, modifiers, held)
      @on_mouse&.call(MouseEvent.new(
        x: x, y: y, area_width: @width, area_height: @height,
        down: down, up: up, count: 1, modifiers: modifiers, held: held
      ))
    end

    def dispatch_key(key, modifiers, up)
      ext = EXT_KEYS[key]
      char = if ext
        nil
      else
        CHARS[key] || (key.length == 1 ? key : nil)
      end
      return false unless ext || char

      !!@on_key&.call(KeyEvent.new(char: char, ext: ext, modifier: 0, modifiers: modifiers, up: up))
    end

    def dispatch_wheel(x, y, amount)
      @on_wheel&.call(x, y, amount)
    end

    def dispatch_crossed(left)
      @on_crossed&.call(left)
    end
  end
end
