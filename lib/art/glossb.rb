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

    txt = link(name, :underline => 'none', :stroke => fg) {}
    stack :margin => 4 do
      background bgfill, :curve => 5
      @txt = para txt, :align => 'center', :margin => 4, :size => 11
      hover { @over.show }
      leave { @over.hide }
    end

    @over = stack :top => 0, :left => 0, :margin => 2, :hidden => true do
      background bgfill, :curve => 5
      @txt_over = para txt, :align => 'center', :margin => 4, :size => 14, :weight => "bold"
    end
    @fg = fg
    click &blk
  end

  def text= txt
    new_link = link(txt, :underline => 'none', :stroke => @fg) {}
    @txt.replace(new_link)
    @txt_over.replace(new_link)
  end
end
