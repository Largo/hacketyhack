#
# A little drawing program. Pick a colour and scribble; the line gets thicker
# the slower you move. Built step by step in the "Make a Drawing Program" lesson.
#
Shoes.app :width => 420, :height => 340, :title => "Draw!" do
  paper = stack :top => 0, :left => 0, :width => 1.0, :height => 1.0 do
    background white
  end

  pen = black

  flow :top => 0, :left => 0, :height => 36 do
    background "#DDD"
    button("black")  { pen = black }
    button("red")    { pen = red }
    button("blue")   { pen = blue }
    button("green")  { pen = green }
    button("rubber") { pen = white }
    button("clear")  { paper.clear { background white } }
  end

  last_x = nil
  last_y = nil

  animate(24) do
    button_down, x, y = self.mouse

    if button_down == 1 and y > 40
      if last_x
        moved = (x - last_x).abs + (y - last_y).abs
        thickness = 12 - moved
        thickness = 2 if thickness < 2

        paper.append do
          stroke pen
          strokewidth thickness
          line last_x, last_y, x, y
        end
      end
      last_x = x
      last_y = y
    else
      last_x = nil
      last_y = nil
    end
  end
end
