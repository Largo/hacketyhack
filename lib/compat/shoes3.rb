# frozen_string_literal: true

# Shoes 3 compatibility for Hackety Hack.
#
# Hackety Hack was written against Shoes 3 ("Policeman"). Clogs implements the
# Shoes API as defined by Lacci, which is close but not identical: Lacci is a
# deliberate re-specification of Shoes and has not yet grown some of Shoes 3's
# corners.
#
# This file fills those gaps for the parts Hackety Hack relies on. Everything
# here is additive -- a method is only defined if the underlying Shoes does not
# already provide it -- so as Lacci catches up these shims quietly stop being
# used.

# Nokogiri comes first on purpose. It carries its own libxml2 inside its
# precompiled extension, but wxWidgets links the system's, and whichever is
# loaded first is the one Nokogiri ends up calling. Under CLOGS_BACKEND=wx in
# the other order Nokogiri silently binds to whatever libxml2 the distribution
# ships -- 2.9.14 against the 2.13.9 it was built for, on Ubuntu 24.04 -- and
# warns about it on stderr. Loading it first keeps its own.
require "nokogiri"

# CLOGS_BACKEND=webview is an alternate Clogs entry point that renders
# through Scarpe's own webview display service instead of Clogs' native
# renderers -- see clogs/lib/clogs/webview.rb. It bypasses clogs.rb's own
# BACKENDS dispatch entirely (Scarpe requires "shoes"/Lacci itself and
# registers its own display service), so it has to branch before that
# require rather than go through Clogs.backend like libui/fox/wx/qt/gtk3/
# nappgui do.
require(ENV["CLOGS_BACKEND"] == "webview" ? "clogs/webview" : "clogs")

# `require "hpricot"` in a user program should find our Nokogiri-backed shim.
$LOAD_PATH.unshift(File.expand_path("../shims", __dir__))

class Shoes
  FONTS = [] unless defined?(FONTS)

  # Shoes 3 exposed the colour table as `Shoes::COLORS`; Lacci keeps it private
  # inside Shoes::Colors. Hackety Hack's splash screen picks random colours
  # from it.
  COLORS = Shoes::Colors.const_get(:COLORS) unless defined?(COLORS)

  class << self
    # Shoes 3 took its options as a trailing hash: `Shoes.app :width => 300`.
    alias_method :__shoes3_app, :app
    def app(opts = {}, **kwargs, &block)
      __shoes3_app(**opts.transform_keys(&:to_sym).merge(kwargs), &block)
    end

    # Shoes 3 opened its bundled manual in a new window. There is no bundled
    # manual here; point at the online one instead of failing.
    unless method_defined?(:show_manual) || respond_to?(:show_manual)
      def show_manual
        Shoes::Compat.open_url("https://github.com/scarpe-team/scarpe/wiki")
      end
    end
  end

  # Helpers that do not belong to any one drawable.
  module Compat
    # Mixed into any object that writes a slot block, so the Shoes DSL keeps
    # working inside the block even though `self` is no longer the app.
    module ShoesDSLDelegation
      def method_missing(name, *args, **kwargs, &block)
        target = Shoes::Compat.dsl_target
        return super unless target

        target.send(name, *args, **kwargs, &block)
      end

      def respond_to_missing?(name, include_private = false)
        target = Shoes::Compat.dsl_target
        return super unless target

        target.respond_to?(name, include_private) ||
          !Shoes::Drawable.drawable_class_by_name(name).nil? ||
          super
      end
    end

    class << self
      # The app that slot-block DSL calls are currently forwarded to. Nested
      # slots stack, so this is a stack rather than a single value.
      def dsl_target
        Array(@dsl_targets).last
      end

      def with_dsl_target(app)
        (@dsl_targets ||= []).push(app)
        yield
      ensure
        @dsl_targets.pop
      end

      # True when a slot block should be instance_eval'd into the app, which is
      # what ordinary Shoes programs expect: blocks written at the top level, or
      # written somewhere that is already the app.
      def app_scoped_block?(owner, app)
        return true if owner.nil?
        return true if owner.equal?(app) || owner.is_a?(Shoes::App)

        owner.equal?(main_object)
      end

      def main_object
        @main_object ||= TOPLEVEL_BINDING.receiver
      end

      def finish_blocks
        @finish_blocks ||= []
      end

      def run_finish_blocks
        blocks = finish_blocks.dup
        finish_blocks.clear
        blocks.each do |block|
          block.call
        rescue StandardError => e
          warn "Hackety Hack: error while shutting down: #{e.class}: #{e.message}"
        end
      end
    end

    module_function

    # The display-side peer of a drawable: it knows where layout put things.
    def display_peer(drawable)
      Shoes::DisplayService.display_service
        &.query_display_drawable_for(drawable.linkable_id, nil_ok: true)
    rescue StandardError
      nil
    end

    def open_url(url)
      opener = case RUBY_PLATFORM
      when /darwin/ then "open"
      when /mingw|mswin/ then "start"
      else "xdg-open"
      end
      system(opener, url.to_s, out: File::NULL, err: File::NULL)
    end
  end
end

class Shoes::App
  # Shoes 3 let an app set its own window background colour.
  attr_accessor :background_color unless method_defined?(:background_color)

  # Shoes 3 addressed the current slot as `app.slot`.
  def slot
    current_slot
  end

  # `close` ends the app, as the Quit tab expects.
  def close
    destroy
  end unless method_defined?(:close)

  # Shoes Classic ran a slot block with `self` still set to the object that
  # wrote the block; Lacci instance_evals it into the app instead. Lacci calls
  # this out as a known incompatibility in Slot#append, and it is the single
  # biggest thing standing between Hackety Hack and running: its tab classes do
  #
  #   slot.append { @content = flow { content } }
  #
  # and read `@content` back later. Under instance_eval that ivar lands on the
  # app and the tab sees nil.
  #
  # So: when a slot block was written inside some other object, keep that object
  # as `self` and forward the Shoes DSL calls it does not understand to the app.
  # When the block was written at the top level or already belongs to the app --
  # which covers ordinary Shoes programs -- nothing changes.
  alias_method :__shoes3_with_slot, :with_slot
  def with_slot(slot_item, &block)
    return unless block

    owner = begin
      block.binding.receiver
    rescue StandardError
      nil
    end

    if Shoes::Compat.app_scoped_block?(owner, self)
      (@__shoes3_outer_selves ||= []).push(owner)
      begin
        __shoes3_with_slot(slot_item, &block)
      ensure
        @__shoes3_outer_selves.pop
      end
    else
      owner.extend(Shoes::Compat::ShoesDSLDelegation) unless owner.is_a?(Shoes::Compat::ShoesDSLDelegation)
      push_slot(slot_item)
      begin
        Shoes::Compat.with_dsl_target(self) { block.call }
      ensure
        pop_slot
      end
    end
  end

  alias_method :__shoes3_method_missing, :method_missing
  def method_missing(name, *args, **kwargs, &block)
    __shoes3_method_missing(name, *args, **kwargs, &block)
  rescue NameError, NoMethodError => e
    outer = Array(@__shoes3_outer_selves).reverse.find do |candidate|
      candidate && !candidate.equal?(self) && candidate.respond_to?(name, true)
    end
    raise e unless outer

    outer.send(name, *args, **kwargs, &block)
  end

  # Shoes 3's class-level styling: `style(Shoes::Link, stroke: "#377")`.
  # Lacci keeps the same idea in drawable_default_styles.
  def style(klass = nil, styles = {})
    return super() if klass.nil?

    Shoes::Drawable.drawable_default_styles[klass].merge!(styles)
  end
end

class Shoes::App
  # Shoes 3 set the mouse pointer shape with `self.cursor = :text`. libui has
  # no cursor API, so this records the value without changing the pointer --
  # Hackety Hack's editor reads it back, so it has to round-trip.
  attr_writer :cursor unless method_defined?(:cursor=)

  def cursor
    @cursor ||= :arrow
  end unless method_defined?(:cursor)
end

class Shoes::Para
  # Shoes 3's `para.cursor = n` put a text caret at character n, and `marker`
  # was the selection anchor. `cursor = :marker` moved the caret to the
  # marker. Clogs draws the caret.
  shoes_styles :text_cursor unless shoes_style_name?(:text_cursor)
  shoes_styles :marker unless shoes_style_name?(:marker)

  def cursor=(position)
    # `cursor = :marker` collapses the selection: caret moves to the marker,
    # or stays put when no marker is set.
    position = marker || text_cursor if position == :marker
    self.text_cursor = position
  end unless method_defined?(:cursor=)

  def cursor
    text_cursor
  end unless method_defined?(:cursor)

  # Shoes 3's `para.highlight` is the selection as [position, length]:
  # zero-length at the caret when no marker is set.
  def highlight
    c = text_cursor.to_i
    m = marker
    m.nil? ? [c, 0] : [[c, m].min, (c - m).abs]
  end unless method_defined?(:highlight)

  # Shoes 3's hit-testing and caret geometry, answered by the display side:
  # `hit(x, y)` is the character index under a window point (nil outside the
  # para), `cursor_top` the caret line's y within the para.
  def hit(x, y)
    peer = __shoes3_display_peer
    peer.respond_to?(:hit) ? peer.hit(x, y) : nil
  end unless method_defined?(:hit)

  def cursor_top
    peer = __shoes3_display_peer
    peer.respond_to?(:caret_top) ? peer.caret_top : 0
  end unless method_defined?(:cursor_top)

  private

  def __shoes3_display_peer
    Shoes::DisplayService.display_service
      &.query_display_drawable_for(linkable_id, nil_ok: true)
  rescue StandardError
    nil
  end
end

# Shoes 3 slots scrolled their own contents; Clogs scrolls only the window
# (see the coverage matrix). Accept the calls so programs run.
class Shoes::Slot
  attr_writer :scroll_top unless method_defined?(:scroll_top=)

  def scroll_top
    @scroll_top || 0
  end unless method_defined?(:scroll_top)
end

# Shoes 3 fires a slot's click/release/hover/leave handlers only when the
# pointer is inside the slot. Lacci models them as app-wide subscriptions,
# so every button's handler fired on every click anywhere -- one click on
# "Save" also ran "New Program" and "Upload", stacking their dialogs. Wrap
# each handler in a hit test against the slot's laid-out box.
class Shoes::Slot
  module Shoes3PositionalEvents
    %i[click release].each do |event|
      define_method(event) do |*args, &blk|
        return super(*args, &blk) unless blk

        slot = self
        super(*args) do |button, x, y|
          peer = Shoes::Compat.display_peer(slot)
          # Only Clogs' peers broadcast click/release app-wide and need a hit
          # test; Scarpe's webview peers are backed by real DOM elements
          # whose click events are already scoped to themselves.
          if peer.respond_to?(:contains?)
            blk.call(button, x, y) if peer.contains?(x, y)
          else
            blk.call(button, x, y)
          end
        end
      end
    end

    # Hover and leave arrive as app-global "the hover target changed" events
    # with no coordinates; the pointer's position decides whether this slot
    # was entered or left.
    #
    # On Clogs, dispatch for these two event names is not actually
    # symmetric for widgets composed of nested slots (e.g. IconButton, which
    # wraps its glyph in an inner `stack`): hit-testing on hover/leave finds
    # whichever nested child peer is topmost at the pointer -- often not the
    # exact slot `hover`/`leave` were called on -- so the "leave"-named
    # dispatch reliably lands on a slot with no `leave` block bound and is a
    # silent no-op, even though the matching "hover" dispatch (fired for the
    # same transition, same misdirected target-resolution) still ends up
    # reaching real bound handlers app-wide. Concretely: leave callbacks
    # registered the normal way never fire, which left every IconButton's
    # hover tooltip and highlight stuck on permanently once shown (visible
    # as several stuck/overlapping tooltips after hovering multiple icons).
    #
    # Rather than depend on the "leave" dispatch, register both the hover
    # and leave blocks on the "hover" channel, which does fire reliably,
    # and detect the falling edge ourselves from shared was-inside state.
    # `hover` sets up the single "hover"-channel dispatch a slot needs, the
    # first time either `hover` or `leave` is called on it (idempotent) --
    # `leave` reuses it via `hover(&nil)` rather than registering its own.
    # No code in this app calls a bare `.hover` with no block expecting a
    # plain getter/no-op, so folding that case into the same setup path is
    # safe here.
    define_method(:hover) do |*args, &blk|
      slot = self
      slot.instance_variable_set(:@shoes3_positional_hover_blk, blk) if blk
      return self if slot.instance_variable_get(:@shoes3_positional_wrapped)

      slot.instance_variable_set(:@shoes3_positional_wrapped, true)
      super(*args) do |*cb_args|
        peer = Shoes::Compat.display_peer(slot)
        unless peer.respond_to?(:app)
          slot.instance_variable_get(:@shoes3_positional_hover_blk)&.call(*cb_args)
          next
        end
        _b, mx, my = peer.app&.mouse_state
        inside = peer.respond_to?(:contains?) && mx && peer.contains?(mx, my)
        was_inside = slot.instance_variable_get(:@shoes3_positional_inside) || false
        slot.instance_variable_set(:@shoes3_positional_inside, inside)
        if inside && !was_inside
          slot.instance_variable_get(:@shoes3_positional_hover_blk)&.call(*cb_args)
        elsif !inside && was_inside
          slot.instance_variable_get(:@shoes3_positional_leave_blk)&.call(*cb_args)
        end
      end
    end

    define_method(:leave) do |*args, &blk|
      return super(*args, &blk) unless blk

      # Stash the block for `hover`'s wrapped closure to call on the falling
      # edge; deliberately do NOT also register a "leave"-named dispatch --
      # see the comment above for why that dispatch is a no-op. `hover(&nil)`
      # just makes sure the shared "hover"-channel dispatch exists even if
      # this slot never calls `hover` itself.
      instance_variable_set(:@shoes3_positional_leave_blk, blk)
      hover(&nil)
    end
  end
  prepend Shoes3PositionalEvents
end

class Shoes::Drawable
  # Shoes 3 predates keyword arguments: styles were passed as a trailing hash,
  # `image(path, :bottom => 0)`. Lacci wants real keywords, so move a trailing
  # hash across before it reaches the argument checker.
  module HashStyleArgs
    def initialize(*args, **kwargs, &block)
      # Widget subclasses declare `init_args :any` and read their own options
      # hash positionally, so leave their arguments alone.
      unless is_a?(Shoes::Widget)
        kwargs = args.pop.transform_keys(&:to_sym).merge(kwargs) if args.last.is_a?(Hash)
      end
      # Shoes 3 called the bold style :weight; Lacci calls it :font_weight.
      if kwargs.key?(:weight) && self.class.shoes_style_name?(:font_weight)
        weight = kwargs.delete(:weight)
        kwargs[:font_weight] ||= weight
      end
      super(*args, **kwargs, &block)
    end
  end
  prepend HashStyleArgs
end

# Para and the text drawables consume their positional args as text children
# in their own initialize, before the prepend on Shoes::Drawable ever runs --
# so `span(token, colors[:any])` would render the style hash as text. Prepend
# the same conversion directly onto them.
[Shoes::Para, Shoes::TextDrawable].each do |klass|
  klass.prepend(Shoes::Drawable::HashStyleArgs)
end

class Shoes::Drawable

  # Shoes 3 could position a drawable from the right or bottom edge of its
  # slot. Lacci has no such styles; register them so they are carried through
  # to the display service, where Clogs' layout understands them.
  shoes_styles :bottom, :right unless shoes_style_name?(:bottom)

  # Shoes 3 styles Lacci does not define, registered so programs load without
  # warnings: trim-wrapping paragraphs and inner-slot scrolling stay
  # unimplemented (see the coverage matrix).
  Shoes::Para.shoes_styles :wrap unless Shoes::Para.shoes_style_name?(:wrap)
  Shoes::Slot.shoes_styles :scroll unless Shoes::Slot.shoes_style_name?(:scroll)

  # Shoes 3's `start` and `finish` fire when a slot is first drawn and when it
  # goes away. Lacci has no slot lifecycle events yet, so `finish` blocks run
  # at process exit -- which is what Hackety Hack uses it for (saving prefs).
  def finish(&block)
    Shoes::Compat.finish_blocks << block if block
    self
  end unless method_defined?(:finish)

  def start(&block)
    block&.call(self)
    self
  end unless method_defined?(:start)

  # Shoes 3 attaches mouse handlers straight to a drawable and returns the
  # drawable, so they chain:
  #
  #   image(path).hover { ... }.leave { ... }.click { ... }
  #
  # In Lacci the bare `hover`/`click` methods instead create a free-standing
  # subscription covering the whole app, which is still what we want when they
  # are called on the app itself.
  %i[hover leave click release].each do |event|
    define_method(event) do |&block|
      return method_missing(event, &block) if is_a?(Shoes::App)
      return self unless block

      # Subscribe directly rather than via bind_self_event: Lacci only lets a
      # drawable bind events its own class declares, and most drawables do not
      # declare `click` even though Shoes 3 let you click anything.
      Shoes::DisplayService.subscribe_to_event(event.to_s, linkable_id) do |*args|
        block.arity.zero? ? block.call : block.call(self, *args)
      end
      # Subscribing is not enough on its own. A drawable that declares a
      # `:click` style uses it to mean "I am clickable" -- Clogs' image asks
      # for exactly that before it will accept a hit -- so a handler attached
      # the Shoes 3 way has to set it too, or the display side never hit-tests
      # the drawable and the subscription above is never fired. This is what
      # made Hackety Hack's sidebar unclickable on every backend: its tab icons
      # are `image(icon).hover{}.leave{}.click{}`, and the hit went to the
      # enclosing slot instead.
      self.click = block if event == :click && self.class.shoes_style_name?("click") && !click_style_set?
      self
    end
  end

  # `click` is both the style getter and the handler-attaching method above, so
  # the style has to be read the long way round.
  def click_style_set?
    !instance_variable_get(:@click).nil?
  end

  # Shoes 3 lets any drawable be toggled or removed.
  def toggle
    self.hidden = !hidden
  end unless method_defined?(:toggle)

  def hide
    self.hidden = true
  end unless method_defined?(:hide)

  def show
    self.hidden = false
  end unless method_defined?(:show)

  # Shoes 3 code that needs a drawable's real on-screen position (Hackety
  # Hack's tooltip placement walks up the parent chain summing :left/:top)
  # assumed every ancestor slot carried an explicit style, which broke on any
  # flow-positioned ancestor -- there the style is simply unset, not 0. The
  # display side already resolves a real absolute position every paint, for
  # hit-testing (Clogs::Drawable#abs_x/#abs_y); expose that instead.
  def absolute_left
    peer = Shoes::Compat.display_peer(self)
    peer.respond_to?(:abs_x) ? peer.abs_x : (left || 0)
  end unless method_defined?(:absolute_left)

  def absolute_top
    peer = Shoes::Compat.display_peer(self)
    peer.respond_to?(:abs_y) ? peer.abs_y : (top || 0)
  end unless method_defined?(:absolute_top)

  # `width`/`height` are plain shoes_styles -- a set value round-tripped back,
  # never the actual rendered size. Shoes 3 could ask an auto-sized drawable
  # (a `para` with no explicit :width) how wide its text came out; Lacci has
  # no such report, so that style stays nil forever. The display side knows
  # -- Clogs::Drawable#measure sets a real @width/@height every layout pass
  # -- so read that instead. Before the first layout pass it is 0, not nil.
  def measured_width
    peer = Shoes::Compat.display_peer(self)
    peer.respond_to?(:width) ? peer.width : (width || 0)
  end unless method_defined?(:measured_width)

  def measured_height
    peer = Shoes::Compat.display_peer(self)
    peer.respond_to?(:height) ? peer.height : (height || 0)
  end unless method_defined?(:measured_height)
end

# Shoes 3's `image(width, height) { ... }` made an off-screen canvas to draw
# into. Clogs has no off-screen surfaces (libui cannot blit one back), so treat
# it as an empty image of that size: the app keeps running and the space is
# reserved, rather than the whole program failing to start.
class Shoes::Image
  module Shoes3Canvas
    def initialize(*args, **kwargs, &block)
      if args.length == 2 && args.all? { |a| a.is_a?(Numeric) }
        width, height = args
        args = [nil]
        kwargs = kwargs.merge(width: width, height: height)
      end
      super(*args, **kwargs, &block)
    end
  end
  prepend Shoes3Canvas

  # Shoes 3 image objects could set their own rotation anchor and rotate
  # themselves directly (`image.transform :center; image.rotate(30)`) --
  # Hackety Hack's Turtle graphics uses this for the little heading arrow.
  # Clogs renders images as filled rectangles (see the coverage matrix), with
  # no rotation support yet; accept the calls without crashing rather than
  # actually rotating anything.
  def transform(_anchor)
    self
  end unless method_defined?(:transform)

  def rotate(_degrees)
    self
  end unless method_defined?(:rotate)
end

# Lacci passes a Widget's block to the widget's own initialize *and* then runs
# it again as the widget's slot body. Its source marks that second call with
# "# Do Widgets do this?" -- Shoes 3 did not. Hackety Hack's widgets take a
# block as their click handler, so running it at creation time fires the
# handler before the widget exists.
#
# Redefine the hook Lacci uses to wrap widget initializers, without that call.
# Hackety Hack's widget classes are defined after this file loads, so they pick
# this version up.
class Shoes::Widget
  def self.method_added(name)
    return if self == ::Shoes::Widget || name != :initialize
    return if @midway_through_adding_initialize

    alias_method :__widget_initialize, :initialize

    @midway_through_adding_initialize = true
    define_method(:initialize) do |*args, **kwargs, &block|
      super(*args, **kwargs, &block)
      @options = kwargs
      create_display_drawable
      __widget_initialize(*args, **kwargs, &block)
    end
    @midway_through_adding_initialize = false
  end
end

# Shoes 3's `mask { ... }` slot has no equivalent in Lacci 0.5.0. Define it so
# programs using it load and lay out; Clogs draws the contents without actually
# masking, which is noted in the coverage matrix.
unless defined?(Shoes::Mask)
  class Shoes::Mask < Shoes::Slot
    include Shoes::Background

    shoes_events # No Mask-specific events

    def initialize(*args, **kwargs, &block)
      super

      create_display_drawable
      @app.with_slot(self, &block) if block
    end
  end
end

# Shoes 3's `shape(left, top) { ... }` took its origin positionally; Lacci only
# accepts it as styles.
class Shoes::Shape
  module Shoes3Origin
    def initialize(*args, **kwargs, &block)
      if args.length == 2 && args.all? { |a| a.is_a?(Numeric) }
        left, top = args
        args = []
        kwargs = { left: left, top: top }.merge(kwargs)
      end
      super(*args, **kwargs, &block)
    end
  end
  prepend Shoes3Origin
end

# Shoes 3's `drawable.style` returns the styles as a symbol-keyed hash, and
# `drawable.style :key => val` sets styles -- as does `drawable.style(a_hash)`
# with a hash captured earlier (Hackety Hack's Turtle graphics round-trips
# one this way to restore an image's styles: `s = @image.style; ...;
# @image.style s`). A bare local variable isn't the `key: val` call syntax
# that Ruby turns into keyword arguments, so that form arrives as a single
# positional Hash instead -- indistinguishable, once inside the method, from
# Shoes 3's *other* `style` overload, `.style(SomeDrawableClass, ...)` for
# class-level defaults, which Lacci still needs to see. Lacci's version
# also returns string keys, needs the app's feature list for a plain read,
# and its setter path writes instance variables without telling the display
# service -- so the change never reaches the screen. Route sets through the
# real setters.
class Shoes::Drawable
  module Shoes3StyleAccess
    def style(*args, **kwargs)
      if args.empty? && kwargs.empty?
        shoes_style_values(with_features: :all).transform_keys(&:to_sym)
      elsif args.length == 1 && args[0].is_a?(Hash)
        # The captured hash is a *read* of every property, including ones
        # that aren't a settable style at all (shoes_linkable_id, an
        # identity, not a style) -- only apply keys that really are one.
        kwargs = args[0].transform_keys(&:to_sym).merge(kwargs)
        kwargs.each { |name, value| send("#{name}=", value) if self.class.shoes_style_name?(name.to_s) }
        nil
      elsif args.empty?
        kwargs.each { |name, value| send("#{name}=", value) }
        nil
      else
        super
      end
    end
  end
  prepend Shoes3StyleAccess
end

# Shoes 3 exposed a para's text items as `contents`, and each item's `parent`
# was the para -- Hackety Hack's home tab restyles its links through both.
# Lacci keeps the items in @text_children and gives text drawables no parent.
class Shoes::Para
  def contents
    Array(@text_children)
  end unless method_defined?(:contents)

  module Shoes3TextChildren
    private

    def update_text_children(children)
      super
      Array(@text_children).each do |child|
        child.instance_variable_set(:@__shoes3_para, self) if child.is_a?(Shoes::TextDrawable)
      end
    end
  end
  prepend Shoes3TextChildren
end

class Shoes::TextDrawable
  module Shoes3Parent
    def parent
      @__shoes3_para || super
    end
  end
  prepend Shoes3Parent
end

# Shoes 3's `drawable.left`/`.top` returned the drawable's laid-out position
# within its slot when no explicit style was set; Lacci only reads the style
# back (nil). The display side knows where layout put everything.
class Shoes::Drawable
  module Shoes3PositionReaders
    def left
      super || __shoes3_display_position(:x)
    end

    def top
      super || __shoes3_display_position(:y)
    end

    private

    def __shoes3_display_position(axis)
      peer = Shoes::DisplayService.display_service
        &.query_display_drawable_for(linkable_id, nil_ok: true)
      peer.respond_to?(axis) ? peer.public_send(axis) : nil
    rescue StandardError
      nil
    end
  end
  prepend Shoes3PositionReaders
end

# Shoes 3 animations respond to `stop`. Lacci has no lifecycle control for
# subscription items, but destroying one stops its timer.
class Shoes::SubscriptionItem
  def stop
    destroy
  end unless method_defined?(:stop)
end

# Shoes 3 patched Range#rand: `(10..80).rand` picks a random member. An
# integer range excludes its end -- Hackety Hack indexes arrays with it.
class Range
  def rand
    result = Kernel.rand * (self.end - self.begin) + self.begin
    self.begin.is_a?(Integer) && self.end.is_a?(Integer) ? result.to_i : result
  end unless method_defined?(:rand)
end

# Shoes 3 let you reposition any drawable after creating it.
class Shoes::Drawable
  def move(new_left, new_top)
    self.left = new_left
    self.top = new_top
    self
  end unless method_defined?(:move)

  def displace(dx, dy)
    self.left = left.to_i + dx
    self.top = top.to_i + dy
    self
  end unless method_defined?(:displace)
end

# Lacci validates arc angles as non-negative, but Shoes 3 programs happily pass
# negative radians to sweep anticlockwise. Normalise into [0, 2pi).
class Shoes::Arc
  module Shoes3Angles
    TWO_PI = Math::PI * 2

    def initialize(*args, **kwargs, &block)
      args = args.each_with_index.map do |value, index|
        index >= 4 && value.is_a?(Numeric) && value.negative? ? value % TWO_PI : value
      end
      %i[angle1 angle2].each do |key|
        kwargs[key] %= TWO_PI if kwargs[key].is_a?(Numeric) && kwargs[key].negative?
      end
      super(*args, **kwargs, &block)
    end
  end
  prepend Shoes3Angles
end

# In Shoes 3, `oval(left, top, width, height)` gave an axis-aligned ellipse.
# Lacci reads the third positional argument as a radius, so a four-argument
# call comes out twice as wide as intended.
class Shoes::Oval
  module Shoes3PositionalArgs
    def initialize(*args, **kwargs, &block)
      if args.length == 4 && !kwargs.key?(:width) && !kwargs.key?(:height)
        left, top, width, height = args
        args = [left, top]
        kwargs = kwargs.merge(width: width, height: height)
      end
      super(*args, **kwargs, &block)
    end
  end
  prepend Shoes3PositionalArgs
end

module Kernel
  # Shoes 3's top-level `window` is how Hackety Hack starts. With no app
  # running it opens the main one; inside a running app Shoes 3 would open a
  # second window, which Clogs does not support yet -- see the coverage matrix.
  unless method_defined?(:window)
    def window(opts = {}, &block)
      Shoes.app(**opts.transform_keys(&:to_sym), &block)
    end
  end

  # Shoes 3's modal `dialog`. Clogs is single-window, so this renders the
  # dialog's contents inside the current app instead of in a new window.
  unless method_defined?(:dialog)
    def dialog(opts = {}, &block)
      app = Shoes::App.instance if Shoes::App.respond_to?(:instance)
      app ||= Shoes.APPS&.last
      return unless app

      app.instance_eval do
        current_slot.stack(top: 0, left: 0, width: 1.0, height: 1.0, &block)
      end
    end
  end
end

# Hackety Hack's turtle graphics are part of the environment user programs run
# in, so make `Turtle` available to anything using this compatibility layer.
begin
  require "lib/art/turtle"
rescue LoadError
  # Running Clogs without the Hackety Hack tree; that is fine.
end

# Slots that registered a `finish` block expect it to run on shutdown.
#
# Shoes 3 ran them while the app was still up. at_exit alone is too late for a
# display library that takes its world down with the event loop: on wx, every
# drawable call after that raises NameError, because the application object the
# fonts and bitmaps belong to no longer exists. So they run as the app is
# destroyed -- which is both closer to Shoes 3 and the only point at which they
# can do anything -- and at_exit stays as the backstop for a block registered
# after that, or by a program that never opened a window at all.
#
# Which App class that is depends on the backend: Clogs::App for every native
# renderer, Scarpe::Webview::App under CLOGS_BACKEND=webview -- only one of
# the two is ever loaded, so pick whichever answered.
hh_app_class =
  if defined?(Clogs::App)
    Clogs::App
  elsif defined?(Scarpe::Webview::App)
    Scarpe::Webview::App
  end
hh_app_class&.prepend(Module.new do
  def destroy
    Shoes::Compat.run_finish_blocks unless @destroyed
    super
  end
end)

at_exit { Shoes::Compat.run_finish_blocks }
