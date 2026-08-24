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
        dispatch(events_json) unless events_json.empty? || events_json == "[]"
        apps.values.each { |app| app.fire_due_timers(now_ms) }
        GreenThreads.run_pending(now_ms)
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

      def round(value)
        value.is_a?(Numeric) ? value.round(2) : nil
      end
    end
  end
end
