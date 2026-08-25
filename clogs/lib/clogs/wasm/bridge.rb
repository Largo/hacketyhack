# frozen_string_literal: true

require "js"
require "json"

module Clogs
  module Wasm
    # The one seam between Ruby and the page.
    #
    # Crossing the wasm/JS boundary is expensive in both directions -- roughly
    # 10us for a Ruby->JS call and rather more for JS->Ruby -- so this is built
    # to cross it as few times as possible rather than to look like a drawing
    # API. A painted frame is *one* call carrying the whole command buffer; a
    # tick is *one* call carrying every input event that arrived since the last
    # one. Everything else here is either cached (text measurement) or rare
    # (dialogs, image loads).
    #
    # The JS side is web/host.js, which owns the canvas, the 2D context and the
    # image registry; `ClogsHost` is the object it installs on `window`.
    module Bridge
      module_function

      def host
        @host ||= begin
          h = JS.global[:ClogsHost]
          raise "ClogsHost is not on the page: web/host.js has to load before Ruby starts" if h.nil? || h.typeof == "undefined"

          h
        end
      end

      def available?
        !JS.global[:ClogsHost].nil? && JS.global[:ClogsHost].typeof != "undefined"
      end

      # ---- painting ------------------------------------------------------

      # One frame. `ops` is a flat array of numbers (see Painter::OPS) and
      # `strings` is the side table the string-taking ops index into: keeping
      # strings out of the numeric array is what lets it serialise as a plain
      # JSON number list instead of a mixed-type one.
      def flush(window_id, ops, strings)
        host.call(:flush, window_id, JSON.generate(ops), JSON.generate(strings))
      end

      # ---- text ----------------------------------------------------------

      # Width, ascent and descent of one string in one CSS font, as measured by
      # the canvas itself. Callers cache; this is the raw call.
      def measure_text(text, font)
        parts = host.call(:measureText, text, font).to_s.split(",")
        [parts[0].to_f, parts[1].to_f, parts[2].to_f]
      end

      # ---- windows -------------------------------------------------------

      def open_window(window_id, title, width, height, resizable)
        host.call(:openWindow, window_id, title.to_s, width.to_i, height.to_i, resizable ? 1 : 0)
      end

      def close_window(window_id)
        host.call(:closeWindow, window_id)
      end

      def window_size(window_id)
        host.call(:windowSize, window_id).to_s.split(",").map(&:to_f)
      end

      def set_cursor(window_id, css_cursor)
        host.call(:setCursor, window_id, css_cursor.to_s)
      end

      # ---- images --------------------------------------------------------

      # Hands an image to the page as a data URL and gets back an integer
      # handle. Decoding is asynchronous -- the browser will not decode a JPEG
      # synchronously for anybody -- so this returns immediately and the page
      # invalidates the layout once the bitmap is ready. #image_size answers
      # 0,0 until then, which is why Image keeps drawing its placeholder box.
      #
      # A data URL rather than the bytes: handing a Ruby string to JS is one
      # copy, where handing over a byte array would be one boundary crossing
      # per pixel.
      def load_image(key, data_url)
        host.call(:loadImage, key.to_s, data_url).to_i
      end

      def image_size(handle)
        host.call(:imageSize, handle).to_s.split(",").map(&:to_i)
      end

      # ---- dialogs -------------------------------------------------------
      #
      # The page puts a real element up and answers later; Runtime#modal parks
      # the frame in between, so `ask` still returns to the line that called
      # it. `dialog_state` is "none", "pending", "cancel" or "ok:<answer>".

      def open_dialog(kind, message)
        host.call(:openDialog, kind.to_s, message.to_s)
        nil
      end

      def dialog_state
        host.call(:dialogState).to_s
      end

      # The browser's own dialogs, for the one case that cannot park: code
      # running before there is a frame to park. They are not always available
      # -- an embedded webview may answer `prompt() is not supported` -- which
      # is why they are the fallback rather than the mechanism.

      def alert(message)
        host.call(:alert, message.to_s)
        nil
      end

      def confirm(message)
        host.call(:confirm, message.to_s) == JS::True
      end

      def ask(message)
        answer = host.call(:ask, message.to_s)
        answer.nil? || answer == JS::Null ? nil : answer.to_s
      end

      # ---- clipboard -----------------------------------------------------

      def clipboard_read
        host.call(:clipboardRead).to_s
      end

      def clipboard_write(text)
        host.call(:clipboardWrite, text.to_s)
        nil
      end
    end
  end
end
