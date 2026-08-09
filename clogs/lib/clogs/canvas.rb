# frozen_string_literal: true

require_relative "ui"
require_relative "painter"

module Clogs
  # Owns a uiArea and turns libui's callbacks into ordinary Ruby ones.
  #
  # Everything Clogs draws lives in a single area per window. That is not a
  # stylistic choice: libui has no container that positions native controls at
  # arbitrary coordinates, and Shoes' layout model requires exactly that. So
  # Clogs paints the whole Shoes document itself and synthesises the widgets
  # Shoes needs. See docs/libui_shoes_coverage.md.
  class Canvas
    attr_reader :area
    attr_accessor :on_draw, :on_mouse, :on_key, :on_crossed

    def initialize(scrolling: false, scroll_width: 0, scroll_height: 0)
      @handler = UI.malloc(UI::L::FFI::AreaHandler)

      @handler.Draw = UI.callback(0, [1, 1, 1]) do |_h, _area, params|
        p = UI::L::FFI::AreaDrawParams.new(params)
        painter = Painter.new(p.Context, p.AreaWidth, p.AreaHeight)
        @on_draw&.call(painter, p)
        0
      end

      @handler.MouseEvent = UI.callback(0, [1, 1, 1]) do |_h, _area, evt|
        e = UI::L::FFI::AreaMouseEvent.new(evt)
        @on_mouse&.call(mouse_event(e))
        0
      end

      @handler.MouseCrossed = UI.callback(0, [1, 1, 0]) do |_h, _area, left|
        @on_crossed&.call(left != 0)
        0
      end

      @handler.DragBroken = UI.callback(0, [1, 1]) { 0 }

      @handler.KeyEvent = UI.callback(1, [1, 1, 1]) do |_h, _area, evt|
        e = UI::L::FFI::AreaKeyEvent.new(evt)
        handled = @on_key&.call(key_event(e))
        handled ? 1 : 0
      end

      @area = if scrolling
        UI::L.new_scrolling_area(@handler, scroll_width, scroll_height)
      else
        UI::L.new_area(@handler)
      end
      @scrolling = scrolling
    end

    def redraw
      UI::L.area_queue_redraw_all(@area)
    end

    def set_scroll_size(w, h)
      return unless @scrolling

      UI::L.area_set_size(@area, w.to_i, h.to_i)
    end

    def scroll_to(x, y, w, h)
      return unless @scrolling

      UI::L.area_scroll_to(@area, x, y, w, h)
    end

    private

    MouseEvent = Struct.new(:x, :y, :area_width, :area_height, :down, :up, :count, :modifiers, :held, keyword_init: true) do
      def button_down?
        held.anybits?(1)
      end
    end

    def mouse_event(e)
      MouseEvent.new(
        x: e.X, y: e.Y, area_width: e.AreaWidth, area_height: e.AreaHeight,
        down: e.Down, up: e.Up, count: e.Count, modifiers: e.Modifiers, held: e.Held1To64
      )
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

    def key_event(e)
      char = e.Key.zero? ? nil : e.Key.chr
      KeyEvent.new(
        char: char, ext: UI::EXT_KEYS[e.ExtKey], modifier: e.Modifier,
        modifiers: e.Modifiers, up: e.Up != 0
      )
    end
  end
end
