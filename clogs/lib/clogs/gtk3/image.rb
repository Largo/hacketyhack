# frozen_string_literal: true

require "gtk3"

module Clogs
  # Bitmaps, blitted and composited.
  #
  # This is the drawable that makes the point of this backend. The libui
  # backend paints a picture as run-length encoded rectangles because libui
  # exports no draw-image call -- and libui draws through Cairo on Linux, which
  # has had `cairo_set_source_surface` all along. Reaching Cairo directly turns
  # the same picture, through the same library, from tens of thousands of fills
  # into one blit with the alpha intact.
  class Image < Drawable
    class << self
      def cache
        @cache ||= {}
      end

      # Pixbufs are ordinary Ruby objects here; the cache is dropped when the
      # app tears down, as on the other backends.
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

        pixbuf = GdkPixbuf::Pixbuf.new(file: path)
        if width&.positive? && height&.positive? && (width != pixbuf.width || height != pixbuf.height)
          pixbuf = pixbuf.scale(width, height, :bilinear)
        end
        pixbuf
      rescue StandardError => e
        warn "Clogs: could not load image #{url.inspect}: #{e.message}"
        nil
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
      @pixbuf = self.class.image_for(style(:url), req_w, req_h)
      if @pixbuf
        @width = @pixbuf.width
        @height = @pixbuf.height
      else
        @width = req_w || 0
        @height = req_h || 0
      end
    end

    def draw(painter, x, y)
      unless @pixbuf
        painter.stroke_rect(x + 0.5, y + 0.5, [@width - 1, 1].max, [@height - 1, 1].max,
          [200, 200, 200, 255], thickness: 1)
        return
      end
      return unless painter.visible?(x, y, @width, @height)

      painter.draw_image(@pixbuf, x, y, @width, @height)
    end

    # The libui backend keeps live path objects per image and frees them before
    # uninit; the decoded pixbuf here belongs to the class-level cache.
    def free_paths; end

    def destroy_self
      @pixbuf = nil
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
