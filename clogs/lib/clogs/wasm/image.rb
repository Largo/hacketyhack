# frozen_string_literal: true

require_relative "bridge"

module Clogs
  # Bitmaps, decoded by the browser.
  #
  # This backend gets image support for free and gets it right: the page
  # decodes PNG and JPEG natively, composites alpha, and scales on the GPU.
  # What it does not do is decode synchronously -- there is no browser API that
  # will -- and Clogs' layout pass wants a size *now*. So a first `measure`
  # starts the decode and answers with the size the Shoes program asked for
  # (or nothing, and draws the placeholder box the other backends draw for a
  # missing file); when the bitmap lands the page invalidates the layout and
  # the next frame has the real dimensions.
  class Image < Drawable
    class << self
      def cache
        @cache ||= {}
      end

      # Handles are the page's, and the page drops them all at once.
      def with_live_paths
        @with_live_paths ||= []
      end

      def free_all_paths
        cache.clear
        with_live_paths.clear
      end

      # Unlike the native backends this does not scale on load: a canvas
      # scales at draw time for nothing, so one decode serves every size.
      def image_for(url, _width = nil, _height = nil)
        return nil if url.nil?

        key = url.to_s
        return cache[key] if cache.key?(key)

        cache[key] = build_image(key)
      end

      def build_image(url)
        data_url = data_url_for(url)
        return nil unless data_url

        Wasm::Bridge.load_image(url, data_url)
      rescue StandardError => e
        warn "Clogs: could not load image #{url.inspect}: #{e.message}"
        nil
      end

      # A local path is read out of the wasm filesystem and handed over inline;
      # a remote one is left to the page, which can fetch it itself (and is the
      # only thing here allowed to, since wasm has no sockets).
      def data_url_for(url)
        return url if url.start_with?("http://", "https://", "data:")
        return nil unless File.exist?(url)

        "data:#{mime_type(url)};base64,#{[File.binread(url)].pack("m0")}"
      end

      MIME_TYPES = {
        ".png" => "image/png", ".jpg" => "image/jpeg", ".jpeg" => "image/jpeg",
        ".gif" => "image/gif", ".webp" => "image/webp", ".bmp" => "image/bmp",
        ".svg" => "image/svg+xml", ".ico" => "image/x-icon"
      }.freeze

      def mime_type(path)
        MIME_TYPES[File.extname(path).downcase] || "application/octet-stream"
      end

      def size_of(handle)
        return [0, 0] if handle.nil?

        Wasm::Bridge.image_size(handle)
      end
    end

    def measure(available_width, available_height = nil)
      req_w = requested_width(available_width)
      req_h = requested_height(available_height)
      @handle = self.class.image_for(style(:url))
      natural_w, natural_h = self.class.size_of(@handle)

      if natural_w.to_i.positive? && natural_h.to_i.positive?
        # An explicit width or height wins; giving only one keeps the aspect.
        @width = req_w&.positive? ? req_w : (req_h&.positive? ? (natural_w * req_h.to_f / natural_h).round : natural_w)
        @height = req_h&.positive? ? req_h : (req_w&.positive? ? (natural_h * req_w.to_f / natural_w).round : natural_h)
      else
        @width = req_w || 0
        @height = req_h || 0
      end
    end

    def draw(painter, x, y)
      natural_w, = self.class.size_of(@handle)
      unless @handle && natural_w.to_i.positive?
        # Not decoded yet, or not there at all. Either way the same empty box
        # the other backends draw for a picture they could not load.
        painter.stroke_rect(x + 0.5, y + 0.5, [@width - 1, 1].max, [@height - 1, 1].max,
          [200, 200, 200, 255], thickness: 1)
        return
      end
      return unless painter.visible?(x, y, @width, @height)

      painter.draw_image(@handle, x, y, @width, @height)
    end

    def free_paths; end

    def destroy_self
      @handle = nil
      super
    end

    def clickable?
      !style(:click).nil?
    end

    def on_release(x, y, _button)
      notify("click") if contains?(x, y) && style(:click)
    end
  end
end
