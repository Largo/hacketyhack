# a glossy button, shared by Hackety Hack's own UI chrome and by Turtle's
# on-canvas controls (see lib/art/turtle.rb)
class Glossb < Shoes::Widget
  def initialize(name, opts={}, &blk)
    fg, bgfill = "#777", "#DDD"
    case opts[:color]
      when "dark"; fg, bgfill = "#CCC", "#000"
      when "yellow"; fg, bgfill = "#FFF", "#7AA"
      when "red"; fg, bgfill = "#FF5", "#F30"
    end

    stack :margin => 4 do
      background bgfill, :curve => 5
      @txt = para link(name, :underline => 'none', :stroke => fg) {},
        :align => 'center', :margin => 4, :size => 11
      hover { @over.show }
      leave { @over.hide }
    end

    @over = stack :top => 0, :left => 0, :margin => 2, :hidden => true do
      background bgfill, :curve => 5
      @txt_over = para link(name, :underline => 'none', :stroke => fg) {},
        :align => 'center', :margin => 4, :size => 14, :weight => "bold"
    end
    @fg = fg
    click &blk
  end

  def text= txt
    # A Link belongs to one parent para; the normal and hover labels each
    # need their own instance rather than sharing one, or setting the
    # second para's content reparents the link away from the first and
    # leaves it empty (see the same fix in #initialize).
    @txt.replace(link(txt, :underline => 'none', :stroke => @fg) {})
    @txt_over.replace(link(txt, :underline => 'none', :stroke => @fg) {})
  end
end
