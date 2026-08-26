# frozen_string_literal: true

require_relative "bridge"

module Clogs
  module Wasm
    # The event loop, which is the page's.
    #
    # Every other backend blocks in a native main loop and calls Ruby back.
    # That is not available here and never will be: wasm runs on the browser's
    # only thread, so a Ruby loop that does not return freezes the page it is
    # drawing into. So the ownership is inverted. Lacci is told the display
    # library's loop "returns" (its own supported mode, the one Clogs already
    # uses for nested windows), `Shoes.app` hands control straight back, and
    # from then on the page's requestAnimationFrame drives everything through
    # #tick: input first, then timers, then the frames that fell out of both.
    #
    # This is also the whole of the automation story. A harness that wants a
    # deterministic frame does not have to race the clock -- it can stop the
    # page's own ticking and call #tick itself.
    module Runtime
      module_function

      def apps
        @apps ||= {}
      end

      def next_window_id
        @next_window_id = (@next_window_id || 0) + 1
      end

      def register(app)
        apps[app.window_id] = app
      end

      def unregister(app)
        apps.delete(app.window_id)
      end

      # Installed on the host once, at the first App#run. Ruby procs cross into
      # JS as functions, so the page can call straight back in.
      def install!
        return if @installed

        @installed = true
        Bridge.host.call(:onTick, ->(now, events) { tick(now.to_f, events.to_s) })
        # Each proc returns something JS can hold: a Ruby object handed back
        # across the boundary has to be convertible, and an Array of Apps is
        # not -- so nothing returns a collection by accident.
        Bridge.host.call(:onImageLoaded, -> { invalidate_layout; nil })
        Bridge.host.call(:onDescribe, ->(window_id) { describe(window_id.to_i.zero? ? nil : window_id.to_i) })
      end

      # The frame clock, in milliseconds, as the page last reported it. Timers
      # are scheduled against this rather than against a wall clock so that a
      # hand-ticked page and a running one behave the same way.
      def now
        @now ||= 0.0
      end

      # A picture finished decoding, so anything sized around it has to be
      # measured again -- a redraw alone would paint the old layout.
      def invalidate_layout
        apps.values.each(&:needs_layout!)
        nil
      end

      # One animation frame: drain the page's input queue, fire whatever timers
      # are due, then repaint every canvas that asked for it. Returns the
      # number of frames painted, which is what makes a harness able to wait
      # for "the app has settled" rather than for a wall-clock delay.
      def tick(now_ms, events_json)
        @now = now_ms

        if @parked
          # A dialog is up and a frame is parked inside Ruby waiting for it.
          # Nothing else runs -- no input, no timers -- because that is what
          # `ask` does in Shoes: it stops the program where it stands. The
          # canvas still repaints, so the app does not go grey behind the
          # dialog.
          queue_events(events_json)
          state = Bridge.dialog_state
          resume_frame(take_parked, state) unless state == "pending"
        else
          run_frame(events_json)
        end

        painted = 0
        apps.values.each do |app|
          next unless app.canvas&.dirty?

          app.canvas.paint
          painted += 1
        end
        painted
      rescue StandardError => e
        App.report_error(e)
        0
      end

      # ---- frames, and parking one -------------------------------------
      #
      # A frame's Ruby runs inside a Fiber so that a dialog can stop halfway
      # through it. Shoes' `ask` returns its answer to the line that called it,
      # and a page cannot block; parking the frame and resuming it when the
      # answer arrives is how it does both. See Wasm::Dialogs.

      def run_frame(events_json)
        queued = @queued_events
        @queued_events = nil

        frame = Fiber.new do
          queued&.each { |batch| dispatch(batch) }
          dispatch(events_json) unless blank_events?(events_json)
          apps.values.each { |app| app.fire_due_timers(@now) }
          GreenThreads.run_pending(@now)
        end
        resume_frame(frame, nil)
      end

      def resume_frame(frame, value)
        @in_frame = true
        frame.resume(value)
        @parked = frame if frame.alive?
      ensure
        @in_frame = false
      end

      def take_parked
        parked = @parked
        @parked = nil
        parked
      end

      # Input that arrives while a frame is parked is kept, not dropped: the
      # click that dismissed the dialog is not the only thing that might have
      # happened.
      def queue_events(events_json)
        return if blank_events?(events_json)

        (@queued_events ||= []) << events_json
      end

      def blank_events?(events_json)
        events_json.nil? || events_json.empty? || events_json == "[]"
      end

      # Put a dialog on the page and park until it is answered, or -- when
      # there is no frame to park -- fall back to the browser's own.
      #
      # A green thread is its own Fiber, so yielding from inside one would
      # suspend that rather than the frame, and its scheduler would resume it
      # with a nil that was never an answer. Those take the fallback too.
      def modal(kind, message)
        message = message.to_s
        return native_modal(kind, message) unless @in_frame && GreenThreads.current.nil?

        Bridge.open_dialog(kind, message)
        Fiber.yield.to_s
      end

      def native_modal(kind, message)
        case kind
        when "confirm" then Bridge.confirm(message) ? "ok:" : "cancel"
        when "ask"
          answer = Bridge.ask(message)
          answer.nil? ? "cancel" : "ok:#{answer}"
        else
          Bridge.alert(message)
          "ok:"
        end
      rescue StandardError => e
        # An embedded webview that refuses dialogs outright lands here.
        App.report_error(e)
        "cancel"
      end

      # The page's event queue, as [kind, window_id, ...] tuples. Anything for
      # a window that has already closed is dropped rather than raising.
      def dispatch(events_json)
        JSON.parse(events_json).each do |event|
          kind = event[0]
          app = apps[event[1]]
          next unless app&.canvas

          case kind
          when "m" then app.canvas.dispatch_mouse(event[2], event[3], event[4], event[5], event[6], event[7])
          when "k" then app.canvas.dispatch_key(event[2], event[3], event[4] == 1)
          when "x" then app.canvas.dispatch_crossed(event[2] == 1)
          when "r" then app.resize(event[2], event[3])
          when "q" then app.quit
          end
        rescue StandardError => e
          App.report_error(e)
        end
      end

      # ---- the automation surface ----------------------------------------
      #
      # Clogs paints a Shoes document into one canvas, so a page driven by an
      # automation harness has pixels and nothing else -- no elements to select,
      # no text to read. These answer for the drawable tree instead: what is on
      # screen, where it is, and what it says. web/host.js exposes them on
      # `window.clogs`.

      def describe(window_id = nil)
        app = window_id ? apps[window_id] : apps.values.first
        return JSON.generate({ error: "no such window" }) unless app

        JSON.generate({
          window: app.window_id,
          title: app.title,
          width: app.canvas&.width,
          height: app.canvas&.height,
          drawables: app.document_root ? describe_drawable(app.document_root) : nil
        })
      end

      # Positions are the ones the last paint used -- absolute, in canvas
      # coordinates -- not the slot-relative ones a drawable is laid out with.
      # A harness wants somewhere to click, and that is the same number
      # `contains?` tests a click against.
      def describe_drawable(peer)
        node = {
          type: peer.class.name.to_s.split("::").last,
          x: round(peer.abs_x),
          y: round(peer.abs_y),
          width: round(peer.width),
          height: round(peer.height)
        }
        text = drawable_text(peer)
        node[:text] = text if text && !text.empty?
        # A paragraph's box is as wide as the slot allows, not as wide as its
        # words: `para "Data Types", :width => 280` is a 280-wide drawable with
        # 66 pixels of ink in it, and the middle of that box is empty space
        # where a click hits nothing. Report where the ink actually is -- both
        # edges, since `:align => "center"` puts it somewhere other than the
        # left -- so aiming at a drawable means aiming at what you can see.
        left, width = ink_box(peer)
        if width && node[:width] && width < node[:width]
          node[:inkLeft] = left
          node[:inkWidth] = width
        end
        node[:clickable] = true if peer.respond_to?(:clickable?) && peer.clickable?
        kids = peer.respond_to?(:children) ? peer.children : nil
        node[:children] = kids.map { |k| describe_drawable(k) } if kids && !kids.empty?
        node.compact
      end

      # Whatever a peer would put on screen as words -- a paragraph's text, a
      # button's label, an edit line's contents.
      #
      # A paragraph does not hold a string: Shoes keeps `text_items`, a mix of
      # literal text and the ids of nested drawables like strong() and link(),
      # which is what lets one para carry several styles. Resolving it here is
      # what makes `para "Welcome to", strong("Hackety Hack")` findable by the
      # words a person would read.
      def drawable_text(peer)
        return peer.label.to_s if peer.respond_to?(:label)

        items = peer.style(:text_items) if peer.respond_to?(:style)
        return text_of_items(items) if items

        value = peer.style(:text) if peer.respond_to?(:style)
        value.is_a?(String) ? value : nil
      rescue StandardError
        nil
      end

      def text_of_items(items)
        Array(items).map do |item|
          nested = DisplayService.instance&.query_display_drawable_for(item, nil_ok: true)
          nested ? drawable_text(nested).to_s : item.to_s
        end.join
      end

      # Where the text actually sits inside the drawable's box, as [left,
      # width], for drawables that lay text out. Taken from the placed words
      # rather than from the paragraph's own width, because alignment moves
      # them and the paragraph's width does not say where they went.
      def ink_box(peer)
        paragraph = peer.instance_variable_get(:@paragraph)
        return [nil, nil] unless paragraph.respond_to?(:placed)

        placed = paragraph.placed.reject { |item| item.text.to_s.strip.empty? }
        return [nil, nil] if placed.empty?

        left = placed.map(&:x).min
        right = placed.map { |item| item.x + item.width }.max
        [round(left), round(right - left)]
      end

      def round(value)
        value.is_a?(Numeric) ? value.round(2) : nil
      end
    end
  end
end
