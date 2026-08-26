class HH::SideTabs
  include HH::Observable

  # A 16-pixel target is a small thing to hit with a mouse, and on a dense
  # display it is physically tiny. The artwork is 16 pixels square -- that is
  # all there is of it -- but it is drawn at ICON_TARGET, which makes the
  # thing you click two and a half times the area it was, in a row with room
  # around it. The cost is a mild softness from the upscale, which a dense
  # display was applying to the 16-pixel version anyway.
  ICON_SIZE = 16
  ICON_TARGET = 26
  TAB_HEIGHT = 38
  SIDEBAR_WIDTH = 48
  HOVER_WIDTH = 140
  def initialize slot, dir
    @slot, @directory = slot, dir
    @n_tabs = {:top => 0, :bottom => 1}
    # tabs whose file has been loaded
    @loaded_tabs = {}
    sidetabs = self
    width = HOVER_WIDTH;
    append_to @slot do
      tip = nil
      right = stack :margin_left => SIDEBAR_WIDTH, :height => 1.0
      left = stack :top => 0, :left => 0, :width => SIDEBAR_WIDTH, :height => 1.0 do
        tip = stack :top => 0, :left => 0, :width => width, :margin => 4,
                    :hidden => true do
          background "#F7A", :curve => 6
          # Clear of the icon column *and* of the highlight a hovered row
          # draws behind its icon, which is as wide as the column and paints
          # after this does. Widening the sidebar has to move the label along
          # with it or the first letter disappears under the highlight.
          para "HOME", :margin => 3, :margin_left => SIDEBAR_WIDTH + 6,
               :stroke => white
        end
        # colored background
        background "#cdc", :width => SIDEBAR_WIDTH
        background "#dfa", :width => SIDEBAR_WIDTH - 2
        background "#fda", :width => SIDEBAR_WIDTH - 9
        background "#daf", :width => SIDEBAR_WIDTH - 16
        background "#aaf", :width => SIDEBAR_WIDTH - 23
        background "#7aa", :width => SIDEBAR_WIDTH - 30
        background "#77a", :width => SIDEBAR_WIDTH - 37
      end
      sidetabs.instance_eval{@left, @right, @tip = left, right, tip}
    end
  end

  # +opts+ is an hash
  # if a block is given no file gets loaded
  def addtab symbol, opts={}, &blk
    # default options
    if not symbol.is_a?(Symbol)
      raise ArgumentError
    end
    tab = opts
    tab[:symbol] = symbol
    tab[:icon] ||= "icon-file.png"
    tab[:position] ||= :top
    tab[:hover] ||= symbol.to_s
    
    pos = tab[:position]
    pixelpos = @n_tabs[pos] * TAB_HEIGHT
    @n_tabs[pos] += 1
    hover = tab[:hover]
    icon_path = HH::STATIC + "/" + tab[:icon]
    tip = @tip
    onclick = proc do
      opentab symbol
    end
    width = HOVER_WIDTH+22;
    inset = ((SIDEBAR_WIDTH - ICON_TARGET) / 2.0).round
    top_inset = ((TAB_HEIGHT - ICON_TARGET) / 2.0).round
    append_to @left do
      # The handlers go on the image, not on the surrounding stack. A slot's
      # `click` in Lacci is an app-wide subscription filtered by a hit test
      # rather than a real hit target, and hanging the sidebar off that
      # stopped it working at all -- so the drawable you click is the icon,
      # and the icon is drawn at ICON_TARGET rather than at the 16 pixels the
      # artwork happens to be.
      stack pos => pixelpos, :left => 0, :width => SIDEBAR_WIDTH,
            :height => TAB_HEIGHT do
        bg = background "#DFA", :height => TAB_HEIGHT - 4, :margin_top => 2,
             :margin_left => 2, :curve => 6, :hidden => true
        image(icon_path, :width => ICON_TARGET, :height => ICON_TARGET,
              :margin_left => inset, :margin_top => top_inset).
          hover do
            bg.show
            tip.parent.width = width
            tip.top = nil
            tip.bottom = nil
            tip.send("#{pos}=", pixelpos)
            tip.contents[1].text = hover
            tip.show
          end.leave do
            bg.hide
            tip.hide
            tip.parent.width = SIDEBAR_WIDTH + 2
          end.click &onclick
      end
    end

    if blk
      @loaded_tabs[symbol] = HH::NoContentSideTab.new blk
    end
  end


  def opentab symbol
    tab = gettab symbol
    if tab.has_content?
      @current_tab.close if @current_tab
      @current_tab = tab
    end
    tab.open
    emit :tab_opened, symbol
  end

  def gettab symbol
    if @loaded_tabs.include? symbol
      return @loaded_tabs[symbol]
    else
      require "app/ui/tabs/#{symbol.downcase}.rb"
      @loaded_tabs[symbol] = self.class.const_get(symbol).new(@right)
    end
  end

private
  def append_to slot, &blk
    slot.app do
      slot.append {self.instance_eval &blk}
    end
  end
end

module HH::HasSideTabs
  def init_tabs slot, dir="app/ui/tabs"
    @__side_tab_class = HH::SideTabs.new slot, dir
    # effectively redirects event to HH::APP
    @__side_tab_class.on_event :tab_opened, :any do |newtab|
      emit :tab_opened, newtab
    end
  end

  # returns the created tab
  def addtab *args, &blk
    @__side_tab_class.addtab *args, &blk
  end
  
  def opentab symbol
    @__side_tab_class.opentab symbol
  end

  def gettab symbol
    @__side_tab_class.gettab symbol
  end
end

class HH::SideTab
  def initialize slot
    @slot = slot
    slot.append do
      @content = flow :hidden => true, :left => 0, :top => 0,
                      :width => 1.0, :height => 1.0 do content end
    end
  end

  def open
    on_click
    if has_content?
      @content.show
    end
  end

  def close
    if has_content?
      @content.hide
    end
  end

  def clear &blk
    @content.clear &blk
  end

  def reset
    clear {content}
  end

  def has_content?
    self.class.method_defined?(:content)
  end

  def method_missing symbol, *args, &blk
    #slot = @slot
    @slot.app.send symbol, *args, &blk
  end

  def on_click
    # by default does nothing
  end
end

class HH::NoContentSideTab < HH::SideTab
  def initialize blk
    @blk = blk
  end
  def on_click
    @blk.call
  end
end

