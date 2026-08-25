# frozen_string_literal: true

require "wx"

module Clogs
  # Bitmaps, blitted and composited.
  #
  # This is the drawable the three backends differ over most, and the one wx
  # has the least trouble with: `wxImage` decodes every common format, scales
  # with a choice of filters, and keeps an alpha channel that Cairo then
  # composites properly against whatever is already on the canvas. It is the
  # blit the FOX backend has without the alpha the FOX backend loses, and the
  # compositing the libui backend has without the tens of thousands of
  # rectangles libui needs to get a picture on screen at all.
  class Image < Drawable
    class << self
      def cache
        @cache ||= {}
      end

      # Kept for the libui backend's interface; wx bitmaps are ordinary Ruby
      # objects and need no explicit teardown, but the cache is dropped with
      # the app that made them.
      def with_live_paths
        @with_live_paths ||= []
      end

      def free_all_paths
        cache.clear
        with_live_paths.clear
      end

      def image_for(url, width, height)
        key = [url, width, height]
        return cache[key] if cache.key?(key)

        cache[key] = build_image(url, width, height)
      end

      def build_image(url, width, height)
        path = local_path(url)
        return nil unless path && File.exist?(path)

        check_handlers
        # wx's image loaders report through the wx log, and libpng is chatty
        # about things that do not stop an image loading -- "iCCP: known
        # incorrect sRGB profile" on half the PNGs on the internet. Clogs
        # decides for itself whether the load worked, and says so in its own
        # words below, so wx's running commentary is silenced for the duration.
        image = nil
        Wx::LogNull.no_log { image = Wx::Image.new(path) }
        unless image&.ok?
          warn "Clogs: could not load image #{url.inspect}"
          return nil
        end

        if width&.positive? && height&.positive? && (width != image.width || height != image.height)
          image = image.scale(width, height, Wx::IMAGE_QUALITY_HIGH)
        end
        Wx::Bitmap.new(image)
      rescue StandardError => e
        warn "Clogs: could not load image #{url.inspect}: #{e.message}"
        nil
      end

      # wxRuby registers every image handler it has when the application
      # starts, and exposes no way to add one back afterwards -- so if the
      # handler list is short, some earlier application has already been
      # started and torn down (see App.run_without_loop) and no format will
      # load. Saying so beats fifty "could not load image" lines.
      def check_handlers
        return if @handlers_checked

        @handlers_checked = true
        return if Wx::Image.handlers.size > 1

        warn "Clogs: wx has #{Wx::Image.handlers.size} image handler(s) registered; " \
             "images will not load. A wx application was started and closed earlier in " \
             "this process, which unregisters them all."
      end

      def local_path(url)
        return nil if url.nil?

        url = url.to_s
        return url unless url.start_with?("http://", "https://")

        download(url)
      end

      def download(url)
        require "tmpdir"
        require "digest"
        require "open-uri"
        dest = File.join(Dir.tmpdir, "clogs-img-#{Digest::SHA256.hexdigest(url)[0, 16]}#{File.extname(url)}")
        return dest if File.exist?(dest)

        URI.parse(url).open { |io| File.binwrite(dest, io.read) }
        dest
      rescue StandardError => e
        warn "Clogs: could not fetch #{url}: #{e.message}"
        nil
      end
    end

    def measure(available_width, available_height = nil)
      req_w = requested_width(available_width)
      req_h = requested_height(available_height)
      @bitmap = self.class.image_for(style(:url), req_w, req_h)
      if @bitmap
        @width = @bitmap.width
        @height = @bitmap.height
      else
        @width = req_w || 0
        @height = req_h || 0
      end
    end

    def draw(painter, x, y)
      unless @bitmap
        painter.stroke_rect(x + 0.5, y + 0.5, [@width - 1, 1].max, [@height - 1, 1].max,
          [200, 200, 200, 255], thickness: 1)
        return
      end
      return unless painter.visible?(x, y, @width, @height)

      painter.draw_image(@bitmap, x, y, @width, @height)
    end

    # The libui backend keeps live path objects per image and frees them before
    # uninit; there is nothing per-drawable to free here.
    def free_paths; end

    def destroy_self
      @bitmap = nil
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
