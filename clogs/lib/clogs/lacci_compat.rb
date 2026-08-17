# frozen_string_literal: true

# Small pieces of the Shoes API that Lacci 0.5.0 does not implement but that
# real Shoes programs use constantly. Each is defined only if the installed
# Lacci lacks it, so newer versions win.

# Lacci 0.5.0 binds a SubscriptionItem's callback twice: once in the
# per-event `case` in its initialize, and once more unconditionally right
# after it. Every animate/every/timer/hover callback would run twice per
# event -- an animation advances at double speed and pays double the work.
# The trailing generic bind is the redundant one, and its id is what ends up
# in @unsub_id, so undo exactly that one.
module Clogs
  module SubscriptionItemSingleBind
    def initialize(*args, **kwargs, &block)
      super
      unsub_id = instance_variable_get(:@unsub_id)
      if unsub_id
        unsub_shoes_event(unsub_id)
        instance_variable_set(:@unsub_id, nil)
      end
    end
  end
end
Shoes::SubscriptionItem.prepend(Clogs::SubscriptionItemSingleBind)

# Shoes lets an art drawable carry its own fill/stroke/strokewidth
# (`star ..., :fill => red`); Lacci 0.5.0 only takes those from the draw
# context.
%w[Star Rect Oval Line Arc Shape Arrow].each do |name|
  next unless Shoes.const_defined?(name)

  klass = Shoes.const_get(name)
  %i[fill stroke strokewidth].each do |style|
    klass.shoes_styles(style) unless klass.shoes_style_name?(style)
  end
end

# Lacci pairs `border` with a real Shoes::Border drawable, but `background`
# only records a `background_color` style on the slot and drops its options
# hash -- so no display drawable is ever created and nothing gets painted.
# Give backgrounds the same treatment borders already have: a drawable the
# display service pairs with a Clogs::Background slot decoration. Shoes 3
# backgrounds also carry geometry (`background "#cdc", :width => 38`) and are
# shown/hidden dynamically, so the drawable keeps its whole options hash and
# `background` returns it.
# Newer Lacci (as paired with Scarpe's webview display service) ships
# `Shoes::Background` itself as a real drawable class, making this shim both
# unnecessary and impossible to load -- reopening it `module Shoes::Background`
# below would raise TypeError against a class. Skip the whole shim there.
background_drawable_needed = !Shoes.const_defined?(:BackgroundDrawable) &&
  !(Shoes.const_defined?(:Background) && Shoes::Background.is_a?(Class))

if background_drawable_needed
  class Shoes::BackgroundDrawable < Shoes::Drawable
    shoes_styles :fill, :curve

    opt_init_args :fill
    def initialize(*args, **kwargs)
      super
      create_display_drawable
    end
  end

  module Shoes::Background
    def background(color, options = {})
      self.background_color = color
      # Lacci only sets the creating app around DSL calls that go through
      # Shoes::App#method_missing, so set it here the same way.
      Shoes::Drawable.with_current_app(@app || Shoes.APPS.last) do
        Shoes::BackgroundDrawable.new(color, **options.transform_keys(&:to_sym))
      end
    end
  end
end

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
  # reports it, per window -- so this has to look up *this* app's own peer,
  # not just whichever Clogs::App happened to be created most recently.
  unless method_defined?(:mouse)
    def mouse
      peer = Shoes::DisplayService.display_service&.query_display_drawable_for(linkable_id, nil_ok: true)
      peer&.mouse_state || [0, 0, 0]
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
end
