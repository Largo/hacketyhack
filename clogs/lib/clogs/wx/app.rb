# frozen_string_literal: true

require_relative "canvas"
require_relative "dialogs"

module Clogs
  # The wx half of Clogs::App.
  #
  # Everything about App that is not window, loop or timer is
  # backend-independent and stays in app.rb; this reopens the class and
  # replaces the calls that were libui.
  #
  # The awkward part is that wxRuby has no way to create an application object
  # without also entering its main loop: `Wx::App.run` takes a block that runs
  # once the loop has started. Lacci, meanwhile, fires "init" and then "run" as
  # two separate events, and expects the window to exist after the first. So
  # the first app in the process defers building its window into the block, and
  # every later one -- a nested Shoes.app, whose loop is already running --
  # builds it immediately.
  class App < Drawable
    class << self
      # True between the moment wx hands control to the block it was started
      # with and the moment its loop returns. `Wx::App.is_main_loop_running`
      # cannot be used for this: it is still false inside that block, so a
      # dialog raised during startup would decide no application existed and
      # try to start a second one, which wx refuses.
      attr_accessor :loop_active

      def ensure_libui!
        loop_active
      end
      alias_method :ensure_backend!, :ensure_libui!

      # wx reports its own errors -- a PNG that will not decode, a font that
      # cannot be found -- through a log target that defaults, in a GUI
      # program, to a modal message box. In a Shoes program nobody is there to
      # dismiss it: one unreachable image URL and the app stops forever with
      # an invisible dialog holding the loop. Funnies, whose comics come off
      # the network, hangs on exactly this. Sending the log to stderr keeps the
      # diagnostics and drops the modality.
      def quiet_logging!
        return if @logging_quieted

        @logging_quieted = true
        Wx::Log.set_active_target(Wx::LogStderr.new)
      rescue StandardError
        nil
      end

      # Builtins that need no window at all. `font` matters more than it
      # looks: Shoes programs register their typefaces at load time, before
      # any app exists -- Hackety Hack calls it five times from the top of its
      # boot -- and routing that through the throwaway-application path below
      # would take the image handlers down with it every time.
      NO_GUI_BUILTINS = %w[font ask_color].freeze

      def run_builtin(cmd, args, window)
        return nil if NO_GUI_BUILTINS.include?(cmd.to_s)
        return run_without_loop(cmd, args) unless loop_active

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

      # Shoes 3 let a dialog be raised before any window existed -- Hackety
      # Hack's own Guessing Game sample is a bare ask/alert loop with no
      # Shoes.app in sight. wx needs a running application for that, so one is
      # started just long enough to show the dialog.
      #
      # This is a last resort, and it is destructive: wxWidgets registers its
      # image handlers when an application starts and *unregisters all of
      # them* when one exits, without ever putting them back. An app that
      # shows a dialog this way and then opens a window finds that no PNG will
      # load any more. wxRuby also refuses to create a second application, so
      # this works exactly once per process. Both limitations are why the
      # no-GUI builtins above are answered without coming through here.
      def run_without_loop(cmd, args)
        answer = nil
        owner = self
        quiet = -> { quiet_logging! }
        # wxRuby instance_evals this block into the Wx::App it creates, so the
        # receiver has to be captured rather than assumed.
        Wx::App.run do
          quiet.call
          owner.loop_active = true
          answer = owner.run_builtin(cmd, args, nil)
          # Nothing else is keeping this loop alive; returning ends it.
        end
        answer
      ensure
        self.loop_active = false
      end
    end

    def init
      @initialized = true
      # A nested Shoes.app arrives with the loop already running, so it can
      # have its window now; the first one has to wait for #run.
      build_window if App.loop_active
    end

    def run
      if App.loop_owner.nil?
        App.loop_owner = self
        owner = self
        # wxRuby instance_evals this block into the Wx::App it creates, so
        # `self` inside it is that app and not this one.
        Wx::App.run do
          # Closing the last window is what ends the loop, for every app in
          # the process rather than only this one.
          Wx.get_app.set_exit_on_frame_delete(true)
          App.quiet_logging!
          App.loop_active = true
          owner.build_window
          owner.start
        end
        App.loop_active = false
        Fonts.clear
        UI.clear_cache
        Painter.clear_cache
        Image.free_all_paths
        App.loop_owner = nil
      else
        App.quiet_logging!
        build_window
        start
        # Lacci calls destroy() the moment a display library's event loop
        # returns. Right for the loop owner, wrong for everyone else: tell it
        # to hand control back to the outer loop instead.
        send_shoes_event("return", event_name: "custom_event_loop", target: @shoes_linkable_id)
      end
    end

    def build_window
      return if @window || @destroyed

      @window = Wx::Frame.new(nil, title: title, size: [app_width, app_height])
      @window.evt_close do |event|
        event.skip
        quit
      end

      @canvas = Canvas.new(@window)
      @canvas.on_draw = method(:on_draw)
      @canvas.on_mouse = method(:on_mouse)
      @canvas.on_key = method(:on_key)
      @canvas.on_crossed = method(:on_crossed)

      sizer = Wx::BoxSizer.new(Wx::VERTICAL)
      sizer.add(@canvas.area, 1, Wx::EXPAND)
      @window.set_sizer(sizer)
    end

    def start
      @window.show
      @canvas.area.set_focus
      @running = true
      arm_timers
      install_test_hooks
    end

    def destroy
      return if @destroyed

      @destroyed = true
      App.instances.delete(self)
      window = @window
      @window = nil
      @canvas&.destroy
      @canvas = nil
      @timers&.each { |t| t.stop if t.is_running }
      @timers = nil

      # Destroying a frame from inside its own close handler is safe in wx, but
      # the frame must not be destroyed twice, and the loop has to outlive this
      # event's own dispatch.
      window&.destroy if window && !window.is_being_deleted
    end

    def redraw!
      return if @destroyed

      @canvas&.redraw
    end

    # wx timers can only exist once the application does, so timers armed while
    # the app is still being built are queued -- Shoes programs routinely call
    # `animate` before the loop starts. A timer object that is not referenced
    # is collected and stops firing, so they are all kept.
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

    def arm_timer(interval_ms, repeat, block)
      # wx hands the timer itself to the handler, so this cannot be a lambda.
      handler = proc do |*|
        next if @destroyed

        begin
          block.call
        rescue StandardError => e
          report_error(e)
        end
      end

      timer = repeat ? Wx::Timer.every(interval_ms, &handler) : Wx::Timer.after(interval_ms, &handler)
      (@timers ||= []) << timer
      timer
    end
  end
end
