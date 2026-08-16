# frozen_string_literal: true

require_relative "ui"
require_relative "painter"

module Clogs
  # Owns a wx window and turns wx's events into the same plain Ruby ones the
  # other two backends produce.
  #
  # As on the other backends the whole Shoes document is painted into a single
  # canvas rather than assembled out of native controls. wx could do it the
  # other way -- it has a real absolute-positioning container, and this is the
  # backend where using native controls would actually be practical -- but this
  # keeps Clogs' own painted widgets so the three can be compared like for
  # like. See docs/backends.md.
  class Canvas
    attr_reader :area
    attr_accessor :on_draw, :on_mouse, :on_key, :on_crossed

    def initialize(parent, scrolling: false, scroll_width: 0, scroll_height: 0)
      @scrolling = scrolling
      @scroll_size = [scroll_width, scroll_height]

      @area = Wx::Panel.new(parent, style: Wx::FULL_REPAINT_ON_RESIZE | Wx::WANTS_CHARS)
      # AutoBufferedPaintDC needs the window to leave its background alone.
      @area.set_background_style(Wx::BG_STYLE_PAINT)
      connect_events
    end

    # Shoes' `download` delivers its callback on a Ruby background thread, and
    # that callback builds drawables, which ask for a repaint. GTK may only be
    # touched from the thread that started it, so the request is queued onto
    # the main loop with wx's CallAfter rather than made from wherever it
    # happened to come from.
    #
    # This is a precaution rather than a fix for anything observed: Funnies,
    # which is four downloads and nothing else, passes with or without it. Off
    # main thread GTK misbehaves when it feels like it, so the cheap guard
    # stays.
    def redraw
      return if @destroyed

      if Thread.current == Thread.main
        @area.refresh
      else
        Wx.get_app&.call_after { @area.refresh unless @destroyed }
      end
    end

    def set_scroll_size(w, h)
      @scroll_size = [w.to_i, h.to_i]
    end

    def scroll_to(_x, _y, _w, _h); end

    def destroy
      @destroyed = true
    end

    private

    def connect_events
      @area.evt_paint { paint }
      @area.evt_erase_background { |_e| } # swallowed: the paint handler fills everything
      @area.evt_motion { |e| mouse(e, down: 0, up: 0) }
      @area.evt_left_down { |e| press(e, 1) }
      @area.evt_left_up { |e| release(e, 1) }
      @area.evt_right_down { |e| press(e, 3) }
      @area.evt_right_up { |e| release(e, 3) }
      @area.evt_left_dclick { |e| press(e, 1) }
      @area.evt_key_down { |e| key_down(e) }
      @area.evt_char { |e| char(e) }
      @area.evt_enter_window { |_e| @on_crossed&.call(false) }
      @area.evt_leave_window { |_e| @on_crossed&.call(true) }
    end

    # ---- painting -------------------------------------------------------

    def paint
      return if @destroyed

      width = @area.size.width
      height = @area.size.height
      return if width <= 0 || height <= 0

      # wx does the double buffering itself, and hands back a device context
      # that a graphics context can wrap.
      Wx::AutoBufferedPaintDC.draw_on(@area) do |dc|
        gc = Wx::GraphicsContext.create(dc)
        next unless gc

        gc.set_antialias_mode(Wx::ANTIALIAS_DEFAULT)
        @on_draw&.call(Painter.new(gc, width, height), nil)
        gc.flush
      end
    end

    # ---- input ----------------------------------------------------------

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

    def modifiers_of(event)
      mods = 0
      mods |= UI::MOD_CTRL if event.control_down
      mods |= UI::MOD_SHIFT if event.shift_down
      mods |= UI::MOD_ALT if event.alt_down
      mods
    end

    def held_of(event)
      held = 0
      held |= 1 if event.left_is_down
      held |= 2 if event.middle_is_down
      held |= 4 if event.right_is_down
      held
    end

    def mouse(event, down:, up:)
      @on_mouse&.call(MouseEvent.new(
        x: event.x, y: event.y,
        area_width: @area.size.width, area_height: @area.size.height,
        down: down, up: up, count: 1,
        modifiers: modifiers_of(event), held: held_of(event)
      ))
    end

    def press(event, button)
      # Key events only reach a window that has the focus, and wx only moves
      # focus when asked.
      @area.set_focus
      @area.capture_mouse unless @area.has_capture?
      mouse(event, down: button, up: 0)
    end

    def release(event, button)
      @area.release_mouse if @area.has_capture?
      mouse(event, down: 0, up: button)
    end

    # wx key codes under the names Clogs' App expects from libui.
    EXT_KEYS = {
      Wx::K_ESCAPE => :escape, Wx::K_INSERT => :insert, Wx::K_DELETE => :delete,
      Wx::K_HOME => :home, Wx::K_END => :end, Wx::K_PAGEUP => :page_up,
      Wx::K_PAGEDOWN => :page_down, Wx::K_UP => :up, Wx::K_DOWN => :down,
      Wx::K_LEFT => :left, Wx::K_RIGHT => :right,
      Wx::K_F1 => :f1, Wx::K_F2 => :f2, Wx::K_F3 => :f3, Wx::K_F4 => :f4,
      Wx::K_F5 => :f5, Wx::K_F6 => :f6, Wx::K_F7 => :f7, Wx::K_F8 => :f8,
      Wx::K_F9 => :f9, Wx::K_F10 => :f10, Wx::K_F11 => :f11, Wx::K_F12 => :f12
    }.freeze

    # Named keys are handled here; anything printable is passed on so that wx
    # translates it through the keyboard layout and delivers it to evt_char,
    # which is where the character the user actually typed shows up.
    def key_down(event)
      name = EXT_KEYS[event.key_code]
      unless name
        event.skip
        return
      end

      handled = @on_key&.call(KeyEvent.new(
        char: nil, ext: name, modifier: 0, modifiers: modifiers_of(event), up: false
      ))
      event.skip unless handled
    end

    def char(event)
      code = event.unicode_key
      code = event.key_code if code.nil? || code.zero?
      char = case code
      when Wx::K_BACK then "\b"
      when Wx::K_RETURN, Wx::K_NUMPAD_ENTER then "\n"
      when Wx::K_TAB then "\t"
      else code >= 32 ? code.chr(Encoding::UTF_8) : nil
      end
      unless char
        event.skip
        return
      end

      handled = @on_key&.call(KeyEvent.new(
        char: char, ext: nil, modifier: 0, modifiers: modifiers_of(event), up: false
      ))
      event.skip unless handled
    end
  end
end
