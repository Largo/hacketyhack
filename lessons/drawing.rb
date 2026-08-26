# encoding: UTF-8

lesson_set "7: Make a Drawing Program" do

  lesson "A window to draw on"
  page "Something to make things with" do
    para "This lesson builds a drawing program: a window you can scribble on, ",
         "with colours to pick and a button to start again. It is short, and at ",
         "the end you will have something you can actually use."
    para "As before, every step is a whole program. ", strong("Open in editor"),
         " and press ", strong("Run"), "."
  end

  page "A sheet of paper" do
    para "Start with somewhere to draw. A ", code("stack"), " is a box that ",
         "holds things; this one is pinned to the corner and told to fill the ",
         "window."
    embed_code <<~CODE, :try_button => true, :name => "Draw"
      Shoes.app :width => 400, :height => 300, :title => "Draw!" do
        paper = stack :top => 0, :left => 0, :width => 1.0, :height => 1.0 do
          background white
        end
      end
    CODE
    para code("1.0"), " means 'all of it' — all the width, all the height. A ",
         "plain ", code("400"), " would mean four hundred pixels, so if you ",
         "resize the window the paper would not follow."
  end

  lesson "Drawing"
  page "Following the mouse" do
    para "Twenty-four times a second, ask where the mouse is. If a button is ",
         "held down, draw a line from where it was last time to where it is now."
    embed_code <<~CODE, :try_button => true, :name => "Draw"
      Shoes.app :width => 400, :height => 300, :title => "Draw!" do
        paper = stack :top => 0, :left => 0, :width => 1.0, :height => 1.0 do
          background white
        end

        last_x = nil
        last_y = nil

        animate(24) do
          button_down, x, y = self.mouse

          if button_down == 1 and last_x
            paper.append do
              stroke black
              strokewidth 3
              line last_x, last_y, x, y
            end
          end

          last_x = x
          last_y = y
        end
      end
    CODE
    para "Drag across the window and you are drawing. Lots of short straight ",
         "lines, end to end, look exactly like a curve."
    para code("paper.append"), " adds to the paper instead of replacing it, ",
         "which is why your drawing stays put instead of vanishing on the next ",
         "frame."
  end

  page "Why the last position?" do
    para "If you drew a dot at the mouse instead of a line from the last ",
         "position, a quick flick of the hand would leave a dotted trail — ",
         "twenty-four dots a second cannot keep up with a fast wrist."
    para "Joining each point to the one before means the speed of your hand ",
         "stops mattering. It is worth trying the dotted version to see the ",
         "difference:"
    embed_code 'paper.append { fill black; nostroke; oval x, y, 4, 4 }'
  end

  lesson "Making it a real program"
  page "Choosing a colour" do
    para "A ", code("button"), " runs a block when it is clicked. These ones ",
         "change a variable, and the drawing code picks the colour up on the ",
         "next frame."
    embed_code <<~CODE
      pen = black

      flow :top => 0, :left => 0, :height => 36 do
        background "#DDD"
        button("black") { pen = black }
        button("red")   { pen = red }
        button("blue")  { pen = blue }
      end
    CODE
    para "The toolbar sits on top of the paper, so the drawing code needs to ",
         "ignore anything that happens up there — otherwise you would scribble ",
         "over your own buttons while reaching for them."
  end

  page "The whole thing" do
    para "Colours, a rubber, and a line that gets thicker the faster you move. ",
         "That last one is one line of arithmetic, and it is what makes it feel ",
         "like a pen rather than a mouse."
    embed_code <<~CODE, :try_button => true, :name => "Draw"
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
    CODE
    para "Letting go of ", code("last_x"), " when the button comes up is what ",
         "stops a stray line being drawn from wherever you last clicked — the ",
         "colour buttons are up there, so without it every colour change would ",
         "leave a streak across your picture."
    para "The rubber is not really a rubber — it is a white pen. That works ",
         "because the paper is white, and it is the kind of shortcut real ",
         "programs are full of."
    para "Things to try: a slider of sizes along the bottom, a button that ",
         "saves what you drew, or a pen that changes colour as it goes with ",
         code("rgb(rand(255), rand(255), rand(255))"), "."
  end

end
