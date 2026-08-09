# frozen_string_literal: true

# Small pieces of the Shoes API that Lacci 0.5.0 does not implement but that
# real Shoes programs use constantly. Each is defined only if the installed
# Lacci lacks it, so newer versions win.

class Shoes::App
  # `app.clear { ... }` empties the top-level slot and optionally refills it.
  # Animated Shoes programs redraw themselves this way on every frame.
  unless method_defined?(:clear)
    def clear(&block)
      root = instance_variable_get(:@document_root)
      root&.clear(&block)
    end
  end

  # `self.mouse` returns [button, x, y]. Clogs tracks the pointer as libui
  # reports it.
  unless method_defined?(:mouse)
    def mouse
      Clogs::App.instance&.mouse_state || [0, 0, 0]
    end
  end

  # Shoes 3's `visit` opened a URL; without a browser widget the best we can do
  # is hand it to the desktop.
  unless method_defined?(:visit)
    def visit(url)
      opener = case RUBY_PLATFORM
      when /darwin/ then "open"
      when /mingw|mswin/ then "start"
      else "xdg-open"
      end
      system(opener, url.to_s, out: File::NULL, err: File::NULL)
    end
  end

  # Shoes 3 read and wrote the system clipboard through the app.
  unless method_defined?(:clipboard)
    def clipboard
      Clogs::Clipboard.read
    end

    def clipboard=(text)
      Clogs::Clipboard.write(text.to_s)
    end
  end
end
