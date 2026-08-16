# frozen_string_literal: true

require_relative "ui"
require_relative "painter"

module Clogs
  # Owns one NAppGUI View and turns the shim's callbacks into the same plain
  # Ruby events the other backends produce.
  #
  # NAppGUI's listeners are objects, and building one per view from Ruby would
  # mean a closure per view per event kind. The shim registers one C listener
  # per kind for the process instead and passes the view along, so the
  # dispatch by view pointer happens here -- a Shoes program can have several
  # windows open.
  class Canvas
    class << self
      def registry
        @registry ||= {}
      end

      def install_callbacks
        return if @callbacks_installed

        @callbacks_installed = true
        Shim.on_paint(Shim.callback(Fiddle::TYPE_VOID,
          [Fiddle::TYPE_VOIDP, Fiddle::TYPE_VOIDP, Fiddle::TYPE_FLOAT, Fiddle::TYPE_FLOAT]) do |view, ctx, w, h|
          registry[view.to_i]&.paint(ctx, w, h)
        end)

        Shim.on_mouse(Shim.callback(Fiddle::TYPE_VOID,
          [Fiddle::TYPE_VOIDP, Fiddle::TYPE_FLOAT, Fiddle::TYPE_FLOAT,
           Fiddle::TYPE_INT, Fiddle::TYPE_INT, Fiddle::TYPE_INT, Fiddle::TYPE_INT]) do |view, x, y, down, up, held, mods|
          registry[view.to_i]&.mouse(x, y, down, up, held, mods)
        end)

        Shim.on_key(Shim.callback(Fiddle::TYPE_INT,
          [Fiddle::TYPE_VOIDP, Fiddle::TYPE_INT, Fiddle::TYPE_INT,
           Fiddle::TYPE_INT, Fiddle::TYPE_INT]) do |view, unicode, keysym, mods, up|
          registry[view.to_i]&.key(unicode, keysym, mods, up) ? 1 : 0
        end)

        Shim.on_crossed(Shim.callback(Fiddle::TYPE_VOID,
          [Fiddle::TYPE_VOIDP, Fiddle::TYPE_INT]) do |view, left|
          registry[view.to_i]&.crossed(left != 0)
        end)
      end
    end

    # X11 keysyms for the keys that are not characters. The shim hands these
    # over untranslated, because NAppGUI's own vkey_t table has no room for
    # most of them (see the comment on the GTK hook in clogs_nappgui.cpp).
    KEYSYMS = {
      0xff08 => :backspace, 0xff09 => :tab, 0xff0d => :return, 0xff1b => :escape,
      0xff50 => :home, 0xff51 => :left, 0xff52 => :up, 0xff53 => :right,
      0xff54 => :down, 0xff55 => :page_up, 0xff56 => :page_down, 0xff57 => :end,
      0xff63 => :insert, 0xff8d => :return, 0xffff => :delete,
      0xffbe => :f1, 0xffbf => :f2, 0xffc0 => :f3, 0xffc1 => :f4, 0xffc2 => :f5,
      0xffc3 => :f6, 0xffc4 => :f7, 0xffc5 => :f8, 0xffc6 => :f9, 0xffc7 => :f10,
      0xffc8 => :f11, 0xffc9 => :f12
    }.freeze

    # Shift, Control, Alt and friends arrive as keystrokes of their own and
    # are not one.
    MODIFIER_KEYSYMS = (0xffe1..0xffee).freeze

    attr_reader :view
    attr_accessor :on_draw, :on_mouse, :on_key, :on_crossed

    def initialize(window, scrolling: false, scroll_width: 0, scroll_height: 0)
      @scrolling = scrolling
      @scroll_size = [scroll_width, scroll_height]
      @view = Shim.window_view(window)
      self.class.install_callbacks
      self.class.registry[@view.to_i] = self
    end

    def redraw
      Shim.view_update(@view) unless @destroyed
    end

    def set_scroll_size(w, h)
      @scroll_size = [w.to_i, h.to_i]
    end

    def scroll_to(_x, _y, _w, _h); end

    def destroy
      @destroyed = true
      self.class.registry.delete(@view.to_i)
    end

    # ---- events from the shim -------------------------------------------

    def paint(ctx, width, height)
      return if @destroyed

      @on_draw&.call(Painter.new(ctx, width, height), nil)
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

    def key(unicode, keysym, mods, up)
      return false if @destroyed
      return false if MODIFIER_KEYSYMS.cover?(keysym)

      named = KEYSYMS[keysym]
      char = nil
      ext = nil
      case named
      when :return then char = "\n"
      when nil
        # gdk_keyval_to_unicode answers 0 for a key with no character, which
        # is every key not in the table above -- a dead key, a media key.
        return false if unicode.zero? || unicode < 32

        char = [unicode].pack("U")
      else
        ext = named
      end

      !!@on_key&.call(KeyEvent.new(
        char: char, ext: ext, modifier: 0, modifiers: mods, up: up != 0
      ))
    end

    def crossed(left)
      return if @destroyed

      @on_crossed&.call(left)
    end
  end
end
