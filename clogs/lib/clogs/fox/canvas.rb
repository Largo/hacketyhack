# frozen_string_literal: true

require_relative "ui"
require_relative "painter"

module Clogs
  # Owns an FXCanvas and turns FOX's messages into the same plain Ruby events
  # the libui backend produces.
  #
  # Everything Clogs draws lives in a single canvas per window, for the reason
  # the coverage matrix gives for libui: Shoes' layout positions drawables at
  # arbitrary coordinates and lets them overlap, so the document is painted
  # rather than assembled out of native controls. FOX would actually allow the
  # other approach -- it has a real absolute-positioning container -- but this
  # backend deliberately keeps Clogs' own painted widgets so that the two
  # backends can be compared like for like.
  #
  # Unlike a uiArea, an FXCanvas is not double buffered, and a Shoes document
  # is painted back to front with overlapping drawables. So the document is
  # painted into an off-screen FXImage and blitted, which is the same call the
  # image drawable uses.
  class Canvas
    attr_reader :area
    attr_accessor :on_draw, :on_mouse, :on_key, :on_crossed

    def initialize(parent, scrolling: false, scroll_width: 0, scroll_height: 0)
      @scrolling = scrolling
      @scroll_size = [scroll_width, scroll_height]
      @app = Fox::FXApp.instance

      @area = Fox::FXCanvas.new(parent, nil, 0, Fox::LAYOUT_FILL)
      @area.enable
      connect_events
    end

    # Painting happens on the next event-loop pass, as with area_queue_redraw.
    def redraw
      @area.update if drawable?
    end

    def set_scroll_size(w, h)
      @scroll_size = [w.to_i, h.to_i]
    end

    def scroll_to(_x, _y, _w, _h); end

    def destroy
      @destroyed = true
      # A Shoes program can close its window from inside a draw handler, which
      # means this can be reached with a device context still open on the back
      # buffer. Freeing the pixmap underneath it makes every remaining call on
      # that context an X error, so the free waits until the frame is done.
      @painting ? @release_pending = true : release_backbuffer
    end

    private

    def connect_events
      @area.connect(Fox::SEL_PAINT) { |_s, _sel, ev| paint(ev) }
      @area.connect(Fox::SEL_MOTION) { |_s, _sel, ev| mouse(ev, down: 0, up: 0) }
      @area.connect(Fox::SEL_LEFTBUTTONPRESS) { |_s, _sel, ev| press(ev, 1) }
      @area.connect(Fox::SEL_LEFTBUTTONRELEASE) { |_s, _sel, ev| release(ev, 1) }
      @area.connect(Fox::SEL_RIGHTBUTTONPRESS) { |_s, _sel, ev| press(ev, 3) }
      @area.connect(Fox::SEL_RIGHTBUTTONRELEASE) { |_s, _sel, ev| release(ev, 3) }
      @area.connect(Fox::SEL_KEYPRESS) { |_s, _sel, ev| key(ev, up: false) }
      @area.connect(Fox::SEL_KEYRELEASE) { |_s, _sel, ev| key(ev, up: true) }
      @area.connect(Fox::SEL_ENTER) { @on_crossed&.call(false); 1 }
      @area.connect(Fox::SEL_LEAVE) { @on_crossed&.call(true); 1 }
    end

    # ---- painting -------------------------------------------------------

    def backbuffer(width, height)
      if @backbuffer.nil? || @backbuffer.width < width || @backbuffer.height < height
        @backbuffer&.destroy
        @backbuffer = Fox::FXImage.new(@app, nil, Fox::IMAGE_SHMI | Fox::IMAGE_SHMP, width, height)
        @backbuffer.create
      end
      @backbuffer
    end

    def release_backbuffer
      @backbuffer&.destroy
      @backbuffer = nil
      @release_pending = false
    end

    def paint(event)
      return 1 unless drawable?

      width = @area.width
      height = @area.height
      return 1 if width <= 0 || height <= 0

      buffer = backbuffer(width, height)
      dc = Fox::FXDCWindow.new(buffer)
      begin
        @painting = true
        @on_draw&.call(Painter.new(dc, width, height), event)
      ensure
        dc.end
        @painting = false
        release_backbuffer if @release_pending
      end

      # A Shoes program may close its window from inside a draw handler --
      # Fractal's turtle finishes its drawing and quits -- and by the time the
      # document has finished painting there is no canvas left to blit onto.
      # Constructing an FXDCWindow on a destroyed drawable aborts the process,
      # so the frame is simply dropped. This is FOX's version of the hazard the
      # libui backend guards against by dropping its area on destroy.
      return 1 unless drawable?

      screen = Fox::FXDCWindow.new(@area, event)
      begin
        screen.drawImage(buffer, 0, 0)
      ensure
        screen.end
      end
      1
    end

    def drawable?
      !@destroyed && @area.created?
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

    def modifiers_of(state)
      mods = 0
      mods |= UI::MOD_CTRL if state.anybits?(Fox::CONTROLMASK)
      mods |= UI::MOD_SHIFT if state.anybits?(Fox::SHIFTMASK)
      mods |= UI::MOD_ALT if state.anybits?(Fox::ALTMASK)
      mods
    end

    def held_of(state)
      held = 0
      held |= 1 if state.anybits?(Fox::LEFTBUTTONMASK)
      held |= 2 if state.anybits?(Fox::MIDDLEBUTTONMASK)
      held |= 4 if state.anybits?(Fox::RIGHTBUTTONMASK)
      held
    end

    def mouse(event, down:, up:, held_override: nil)
      @on_mouse&.call(MouseEvent.new(
        x: event.win_x, y: event.win_y,
        area_width: @area.width, area_height: @area.height,
        down: down, up: up, count: event.click_count.to_i,
        modifiers: modifiers_of(event.state),
        held: held_override || held_of(event.state)
      ))
      1
    end

    def press(event, button)
      # The canvas has to hold focus for key events to arrive at all, and FOX
      # only moves focus on an explicit request.
      @area.setFocus
      @area.grab
      # FOX reports the button state as it was *before* the press, so a click
      # would otherwise look like "no button held" to the hover tracking.
      mouse(event, down: button, up: 0, held_override: held_of(event.state) | (1 << (button - 1)))
    end

    def release(event, button)
      @area.ungrab
      mouse(event, down: 0, up: button)
    end

    # FOX's key codes, under the names Clogs' App expects from libui.
    EXT_KEYS = {
      Fox::KEY_Escape => :escape, Fox::KEY_Insert => :insert, Fox::KEY_Delete => :delete,
      Fox::KEY_Home => :home, Fox::KEY_End => :end, Fox::KEY_Page_Up => :page_up,
      Fox::KEY_Page_Down => :page_down, Fox::KEY_Up => :up, Fox::KEY_Down => :down,
      Fox::KEY_Left => :left, Fox::KEY_Right => :right,
      Fox::KEY_F1 => :f1, Fox::KEY_F2 => :f2, Fox::KEY_F3 => :f3, Fox::KEY_F4 => :f4,
      Fox::KEY_F5 => :f5, Fox::KEY_F6 => :f6, Fox::KEY_F7 => :f7, Fox::KEY_F8 => :f8,
      Fox::KEY_F9 => :f9, Fox::KEY_F10 => :f10, Fox::KEY_F11 => :f11, Fox::KEY_F12 => :f12
    }.freeze

    def key(event, up:)
      # FOX hands over the text the keyboard layout actually produced, so
      # unlike libui there is no shift table to maintain and non-US layouts
      # report the character the user typed.
      text = event.text.to_s
      char = text.empty? ? nil : text
      char = nil if char && char.ord < 32 && !["\b", "\r", "\n", "\t", "\x7F"].include?(char)

      handled = @on_key&.call(KeyEvent.new(
        char: char, ext: EXT_KEYS[event.code], modifier: 0,
        modifiers: modifiers_of(event.state), up: up
      ))
      handled ? 1 : 0
    end
  end
end
