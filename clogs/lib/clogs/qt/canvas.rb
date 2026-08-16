# frozen_string_literal: true

require_relative "ui"
require_relative "painter"

module Clogs
  # Owns one Qt canvas widget and turns the shim's callbacks into the same
  # plain Ruby events the other backends produce.
  #
  # Qt delivers its events to whichever canvas they happened on, so the
  # callbacks are registered once for the process and dispatched here by the
  # widget pointer -- there is one Canvas per window, and a Shoes program can
  # have several windows open.
  class Canvas
    class << self
      def registry
        @registry ||= {}
      end

      def install_callbacks
        return if @callbacks_installed

        @callbacks_installed = true
        Shim.on_paint(Shim.callback(Fiddle::TYPE_VOID,
          [Fiddle::TYPE_VOIDP, Fiddle::TYPE_VOIDP, Fiddle::TYPE_DOUBLE, Fiddle::TYPE_DOUBLE]) do |canvas, painter, w, h|
          registry[canvas.to_i]&.paint(painter, w, h)
        end)

        Shim.on_mouse(Shim.callback(Fiddle::TYPE_VOID,
          [Fiddle::TYPE_VOIDP, Fiddle::TYPE_DOUBLE, Fiddle::TYPE_DOUBLE,
           Fiddle::TYPE_INT, Fiddle::TYPE_INT, Fiddle::TYPE_INT, Fiddle::TYPE_INT]) do |canvas, x, y, down, up, held, mods|
          registry[canvas.to_i]&.mouse(x, y, down, up, held, mods)
        end)

        Shim.on_key(Shim.callback(Fiddle::TYPE_INT,
          [Fiddle::TYPE_VOIDP, Fiddle::TYPE_VOIDP, Fiddle::TYPE_VOIDP,
           Fiddle::TYPE_INT, Fiddle::TYPE_INT]) do |canvas, text, ext, mods, up|
          registry[canvas.to_i]&.key(Shim.string(text), Shim.string(ext), mods, up) ? 1 : 0
        end)

        Shim.on_crossed(Shim.callback(Fiddle::TYPE_VOID,
          [Fiddle::TYPE_VOIDP, Fiddle::TYPE_INT]) do |canvas, left|
          registry[canvas.to_i]&.crossed(left != 0)
        end)
      end
    end

    attr_reader :area
    attr_accessor :on_draw, :on_mouse, :on_key, :on_crossed

    def initialize(window, scrolling: false, scroll_width: 0, scroll_height: 0)
      @scrolling = scrolling
      @scroll_size = [scroll_width, scroll_height]
      @area = Shim.window_canvas(window)
      self.class.install_callbacks
      self.class.registry[@area.to_i] = self
    end

    def redraw
      Shim.canvas_update(@area) unless @destroyed
    end

    def set_scroll_size(w, h)
      @scroll_size = [w.to_i, h.to_i]
    end

    def scroll_to(_x, _y, _w, _h); end

    def destroy
      @destroyed = true
      self.class.registry.delete(@area.to_i)
    end

    # ---- events from the shim -------------------------------------------

    def paint(painter, width, height)
      return if @destroyed

      @on_draw&.call(Painter.new(painter, width, height), nil)
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

    def mouse(x, y, down, up, held, mods)
      return if @destroyed

      @on_mouse&.call(MouseEvent.new(
        x: x, y: y, area_width: 0, area_height: 0,
        down: down, up: up, count: 1, modifiers: mods, held: held
      ))
    end

    def key(text, ext, mods, up)
      return false if @destroyed

      # Control characters arrive as text too; Clogs wants the named key for
      # those and the character for everything printable.
      char = text
      char = nil if char && char.length == 1 && char.ord < 32 &&
        !["\b", "\r", "\n", "\t", "\x7F"].include?(char)
      char = "\n" if char == "\r"

      !!@on_key&.call(KeyEvent.new(
        char: char, ext: ext&.to_sym, modifier: 0, modifiers: mods, up: up != 0
      ))
    end

    def crossed(left)
      return if @destroyed

      @on_crossed&.call(left)
    end
  end
end
