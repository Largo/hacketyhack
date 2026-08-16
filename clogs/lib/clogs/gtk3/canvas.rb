# frozen_string_literal: true

require_relative "ui"
require_relative "painter"

module Clogs
  # Owns a Gtk::DrawingArea and turns GTK's signals into the same plain Ruby
  # events the other backends produce.
  #
  # As everywhere else, the whole Shoes document is painted into one canvas
  # rather than assembled out of native controls. GTK could do the other thing
  # -- Gtk::Fixed places a widget at an arbitrary point, which is exactly what
  # libui's coverage matrix says libui cannot do -- but this keeps Clogs' own
  # painted widgets so the five can be compared like for like.
  class Canvas
    attr_reader :area
    attr_accessor :on_draw, :on_mouse, :on_key, :on_crossed

    EVENT_MASK = Gdk::EventMask::BUTTON_PRESS_MASK |
      Gdk::EventMask::BUTTON_RELEASE_MASK |
      Gdk::EventMask::POINTER_MOTION_MASK |
      Gdk::EventMask::KEY_PRESS_MASK |
      Gdk::EventMask::KEY_RELEASE_MASK |
      Gdk::EventMask::ENTER_NOTIFY_MASK |
      Gdk::EventMask::LEAVE_NOTIFY_MASK

    def initialize(_window = nil, scrolling: false, scroll_width: 0, scroll_height: 0)
      @scrolling = scrolling
      @scroll_size = [scroll_width, scroll_height]

      @area = Gtk::DrawingArea.new
      @area.add_events(EVENT_MASK)
      @area.can_focus = true
      connect_signals
    end

    def redraw
      @area.queue_draw unless @destroyed
    end

    def set_scroll_size(w, h)
      @scroll_size = [w.to_i, h.to_i]
    end

    def scroll_to(_x, _y, _w, _h); end

    def destroy
      @destroyed = true
    end

    private

    def connect_signals
      @area.signal_connect("draw") do |widget, cr|
        unless @destroyed
          @on_draw&.call(Painter.new(cr, widget.allocated_width, widget.allocated_height), nil)
        end
        true
      end

      @area.signal_connect("motion-notify-event") { |_w, e| mouse(e, down: 0, up: 0) }
      @area.signal_connect("button-press-event") { |_w, e| press(e) }
      @area.signal_connect("button-release-event") { |_w, e| release(e) }
      @area.signal_connect("key-press-event") { |_w, e| key(e, up: false) }
      @area.signal_connect("key-release-event") { |_w, e| key(e, up: true) }
      @area.signal_connect("enter-notify-event") { @on_crossed&.call(false); false }
      @area.signal_connect("leave-notify-event") { @on_crossed&.call(true); false }
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

    def modifiers_of(state)
      mods = 0
      mods |= UI::MOD_CTRL if state.control_mask?
      mods |= UI::MOD_SHIFT if state.shift_mask?
      mods |= UI::MOD_ALT if state.mod1_mask?
      mods
    end

    def held_of(state)
      held = 0
      held |= 1 if state.button1_mask?
      held |= 2 if state.button2_mask?
      held |= 4 if state.button3_mask?
      held
    end

    def mouse(event, down:, up:, held_override: nil)
      @on_mouse&.call(MouseEvent.new(
        x: event.x, y: event.y,
        area_width: @area.allocated_width, area_height: @area.allocated_height,
        down: down, up: up, count: 1,
        modifiers: modifiers_of(event.state), held: held_override || held_of(event.state)
      ))
      false
    end

    def press(event)
      @area.grab_focus
      # GTK reports the button state as it was *before* the press, so the hover
      # tracking would otherwise see "nothing held" during a click.
      mouse(event, down: event.button, up: 0,
        held_override: held_of(event.state) | (1 << (event.button - 1)))
    end

    def release(event)
      mouse(event, down: 0, up: event.button)
    end

    # GDK key values under the names Clogs' App expects from libui.
    EXT_KEYS = {
      Gdk::Keyval::KEY_Escape => :escape, Gdk::Keyval::KEY_Insert => :insert,
      Gdk::Keyval::KEY_Delete => :delete, Gdk::Keyval::KEY_Home => :home,
      Gdk::Keyval::KEY_End => :end, Gdk::Keyval::KEY_Page_Up => :page_up,
      Gdk::Keyval::KEY_Page_Down => :page_down, Gdk::Keyval::KEY_Up => :up,
      Gdk::Keyval::KEY_Down => :down, Gdk::Keyval::KEY_Left => :left,
      Gdk::Keyval::KEY_Right => :right,
      Gdk::Keyval::KEY_F1 => :f1, Gdk::Keyval::KEY_F2 => :f2, Gdk::Keyval::KEY_F3 => :f3,
      Gdk::Keyval::KEY_F4 => :f4, Gdk::Keyval::KEY_F5 => :f5, Gdk::Keyval::KEY_F6 => :f6,
      Gdk::Keyval::KEY_F7 => :f7, Gdk::Keyval::KEY_F8 => :f8, Gdk::Keyval::KEY_F9 => :f9,
      Gdk::Keyval::KEY_F10 => :f10, Gdk::Keyval::KEY_F11 => :f11, Gdk::Keyval::KEY_F12 => :f12
    }.freeze

    def key(event, up:)
      ext = EXT_KEYS[event.keyval]
      # GDK translates the keyval through the layout, so this is the character
      # the user actually typed -- no shift table, no US-layout assumption.
      char = if ext
        nil
      else
        unicode = Gdk::Keyval.to_unicode(event.keyval)
        case event.keyval
        when Gdk::Keyval::KEY_BackSpace then "\b"
        when Gdk::Keyval::KEY_Return, Gdk::Keyval::KEY_KP_Enter then "\n"
        when Gdk::Keyval::KEY_Tab then "\t"
        else unicode.positive? && unicode >= 32 ? [unicode].pack("U") : nil
        end
      end
      return false unless ext || char

      !!@on_key&.call(KeyEvent.new(
        char: char, ext: ext, modifier: 0, modifiers: modifiers_of(event.state), up: up
      ))
    end
  end
end
