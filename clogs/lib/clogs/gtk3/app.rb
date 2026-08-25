# frozen_string_literal: true

require "gtk3"

require_relative "canvas"
require_relative "dialogs"

module Clogs
  # The GTK3 half of Clogs::App.
  #
  # Everything about App that is not window, loop or timer is
  # backend-independent and stays in app.rb; this reopens the class and
  # replaces the calls that were libui -- which, on Linux, were calls into this
  # same library one wrapper further down.
  class App < Drawable
    class << self
      attr_accessor :gtk_initialized

      # ruby-gnome 4 removed Gtk.main and Gtk.main_quit; the loop they wrapped
      # is GLib's, so this uses it directly. One loop serves every window in
      # the process, as libui's does.
      def main_loop
        @main_loop ||= GLib::MainLoop.new
      end

      def reset_main_loop
        @main_loop = nil
      end

      # There is nothing to call. ruby-gnome initialises GTK as the binding
      # loads, exposes no Gtk.init at all, and segfaults if the leftover
      # Gtk.init_check is called afterwards -- so `require "gtk3"` is the
      # whole of it, and this only records that it has happened.
      def ensure_libui!
        self.gtk_initialized = true
      end
      alias_method :ensure_backend!, :ensure_libui!

      def run_builtin(cmd, args, window)
        ensure_libui!
        case cmd.to_s
        when "alert" then Dialogs.alert(window, args[0])
        when "confirm" then Dialogs.confirm(window, args[0])
        when "ask" then Dialogs.ask(window, args[0])
        when "ask_open_file" then Dialogs.open_file(window)
        when "ask_save_file" then Dialogs.save_file(window)
        when "ask_open_folder" then Dialogs.open_folder(window)
        when "ask_color" then nil
        when "font" then nil
        end
      rescue StandardError => e
        report_error(e)
        nil
      end
    end

    def init
      App.ensure_libui!
      @initialized = true

      @window = Gtk::Window.new(:toplevel)
      @window.title = title
      @window.set_default_size(app_width, app_height)
      @window.signal_connect("delete-event") do
        quit
        true # Clogs decides when the window really goes.
      end

      @canvas = Canvas.new(@window)
      @canvas.on_draw = method(:on_draw)
      @canvas.on_mouse = method(:on_mouse)
      @canvas.on_key = method(:on_key)
      @canvas.on_crossed = method(:on_crossed)
      @window.add(@canvas.area)
    end

    def run
      @window.show_all
      @canvas.area.grab_focus
      @running = true
      arm_timers
      install_test_hooks

      if App.loop_owner.nil?
        # The first app in the process owns the shared GTK loop; every window
        # created while it runs -- including a nested Shoes.app -- is serviced
        # by the same Gtk.main.
        App.loop_owner = self
        App.main_loop.run
        Fonts.clear
        Image.free_all_paths
        App.reset_main_loop
        App.loop_owner = nil
      else
        # Lacci calls destroy() the moment a display library's event loop
        # returns. Right for the loop owner, wrong for everyone else.
        send_shoes_event("return", event_name: "custom_event_loop", target: @shoes_linkable_id)
      end
    end

    def destroy
      return if @destroyed

      @destroyed = true
      App.instances.delete(self)
      window = @window
      @window = nil
      @canvas&.destroy
      @canvas = nil
      live_timers.each_key { |id| GLib::Source.remove(id) }
      live_timers.clear

      window&.destroy if window
      # Quitting ends the shared loop for every window at once, so it waits
      # until this was the last one standing: one nested window closing must
      # not take the process down.
      App.main_loop.quit if App.instances.empty? && App.loop_owner
    end

    def redraw!
      return if @destroyed

      @canvas&.redraw
    end

    # GLib timeouts can be armed before the loop starts, unlike libui's, but
    # the queueing is kept so every backend behaves the same way when a Shoes
    # program calls `animate` while the app is still being built.
    def add_timer(interval_ms, repeat: true, &block)
      interval_ms = 1 if interval_ms.to_i < 1
      unless @running
        (@pending_timers ||= []) << [interval_ms, repeat, block]
        return
      end

      arm_timer(interval_ms, repeat, block)
    end

    def arm_timers
      pending = @pending_timers || []
      @pending_timers = nil
      pending.each { |interval, repeat, block| arm_timer(interval, repeat, block) }
    end

    # Sources that have not yet removed themselves. A GLib source that
    # returns false is gone, and removing it again is a GLib-CRITICAL on
    # stderr rather than a Ruby exception -- so it cannot be rescued, only
    # avoided. Fractal, which quits from inside its own animation, hit it.
    def live_timers
      @live_timers ||= {}
    end

    # Returning true keeps a GLib timeout running; false removes it.
    def arm_timer(interval_ms, repeat, block)
      id = nil
      id = GLib::Timeout.add(interval_ms) do
        keep = false
        unless @destroyed
          begin
            block.call
          rescue StandardError => e
            report_error(e)
          end
          keep = repeat && !@destroyed
        end
        live_timers.delete(id) unless keep
        keep
      end
      live_timers[id] = true
      id
    end
  end
end
