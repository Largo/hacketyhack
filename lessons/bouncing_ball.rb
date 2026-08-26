# encoding: UTF-8

lesson_set "6: Make Something Move" do

  lesson "A ball on the screen"
  page "Something that moves" do
    para "So far your programs have said things. This one is going to ",
         strong("do"), " something: a ball that flies around the window, ",
         "bounces off the walls, and eventually turns into a game you can play."
    para "Every step is a whole program. Click ", strong("Open in editor"), " on ",
         "any of them and press ", strong("Run"), " to see it go. Then change a ",
         "number and run it again — that is the fastest way to learn what each ",
         "part does."
  end

  page "First, a ball" do
    para "A ball is just an ", code("oval"), ". Here is one sitting in the ",
         "middle of a window."
    embed_code <<~CODE, :try_button => true, :name => "Bouncing Ball"
      Shoes.app :width => 400, :height => 300 do
        background white
        nostroke
        fill red
        oval 180, 130, 40, 40
      end
    CODE
    para "The four numbers are ", code("left"), ", ", code("top"), ", ",
         code("width"), " and ", code("height"), ". ", code("nostroke"),
         " says 'no outline', and ", code("fill red"), " says what colour to ",
         "paint it. Try ", code("blue"), ", or make the last two numbers bigger."
  end

  lesson "Making it move"
  page "Draw it again, and again" do
    para "Nothing moves on its own. To animate something you draw it over and ",
         "over, a little further along each time. ", code("animate"), " is how ",
         "you ask Shoes to run a block again and again — twenty times a second here."
    embed_code <<~CODE, :try_button => true, :name => "Bouncing Ball"
      Shoes.app :width => 400, :height => 300 do
        x = 0

        animate(20) do
          clear do
            background white
            nostroke
            fill red
            oval x, 130, 40, 40
          end
          x = x + 4
        end
      end
    CODE
    para code("clear"), " wipes the window before each frame. Without it you ",
         "would leave a trail of every ball you had ever drawn — which is a ",
         "nice effect, so try taking it out and see."
  end

  page "It keeps going" do
    para "Run that and the ball sails off the right-hand edge and never comes back. ",
         "It needs to know where the wall is."
    para "The window knows how wide it is: ", code("width"), ". The ball is 40 ",
         "across, so the far wall — as far as the ball's left edge is concerned — ",
         "is at ", code("width - 40"), "."
  end

  lesson "Bouncing"
  page "Turning around" do
    para "Instead of always adding 4, keep the amount to move in its own ",
         "variable. Call it ", code("dx"), ", for 'change in x'. To bounce, ",
         "flip it from 4 to -4."
    embed_code <<~CODE, :try_button => true, :name => "Bouncing Ball"
      Shoes.app :width => 400, :height => 300 do
        x = 0
        dx = 4

        animate(20) do
          clear do
            background white
            nostroke
            fill red
            oval x, 130, 40, 40
          end

          x = x + dx
          dx = -dx if x < 0 or x > width - 40
        end
      end
    CODE
    para code("dx = -dx"), " is the whole trick. Minus a minus is a plus, so ",
         "the ball turns around every time it hits a wall, for ever."
  end

  page "Up and down as well" do
    para "One more variable and the ball can move in both directions at once. ",
         "The ceiling and the floor work exactly like the walls did."
    embed_code <<~CODE, :try_button => true, :name => "Bouncing Ball"
      Shoes.app :width => 400, :height => 300 do
        x = 0
        y = 0
        dx = 4
        dy = 3

        animate(20) do
          clear do
            background white
            nostroke
            fill red
            oval x, y, 40, 40
          end

          x = x + dx
          y = y + dy
          dx = -dx if x < 0 or x > width - 40
          dy = -dy if y < 0 or y > height - 40
        end
      end
    CODE
    para "Because ", code("dx"), " and ", code("dy"), " are different numbers, ",
         "the ball crosses the window at an angle and the pattern takes a long ",
         "time to repeat. Make them the same and watch it get boring."
  end

  page "A different colour every bounce" do
    para "A bounce is a moment in your program, so you can make anything happen ",
         "there. ", code("rgb"), " builds a colour out of three numbers, and ",
         code("rand(255)"), " picks a random one."
    embed_code <<~CODE, :try_button => true, :name => "Bouncing Ball"
      Shoes.app :width => 400, :height => 300 do
        x = 0
        y = 0
        dx = 4
        dy = 3
        colour = red

        animate(20) do
          clear do
            background white
            nostroke
            fill colour
            oval x, y, 40, 40
          end

          x = x + dx
          y = y + dy

          if x < 0 or x > width - 40
            dx = -dx
            colour = rgb(rand(255), rand(255), rand(255))
          end

          if y < 0 or y > height - 40
            dy = -dy
            colour = rgb(rand(255), rand(255), rand(255))
          end
        end
      end
    CODE
  end

  lesson "Now make it a game"
  page "A bat you can move" do
    para "A game needs you in it. ", code("self.mouse"), " tells you what the ",
         "mouse is doing: whether a button is down, and where the pointer is."
    embed_code 'button_down, mouse_x, mouse_y = self.mouse'
    para "Draw a bat at ", code("mouse_x"), " and it follows your hand. Take ",
         "40 off so the bat is centred on the pointer rather than starting there."
  end

  page "Catch!" do
    para "Here is the whole game. The ball bounces off three walls, but not the ",
         "floor — down there it only bounces if the bat is in the way. Miss it ",
         "and you lose a life."
    embed_code <<~CODE, :try_button => true, :name => "Catch"
      Shoes.app :width => 400, :height => 320, :title => "Catch!" do
        ball_x = 180
        ball_y = 0
        dx = 4
        dy = 3
        score = 0
        lives = 3

        animate(20) do
          button_down, mouse_x, mouse_y = self.mouse
          bat_x = mouse_x - 40

          if lives > 0
            ball_x = ball_x + dx
            ball_y = ball_y + dy
            dx = -dx if ball_x < 0 or ball_x > width - 30
            dy = -dy if ball_y < 0

            hit = ball_x + 30 > bat_x and ball_x < bat_x + 80
            if ball_y > height - 32 and dy > 0 and hit
              dy = -dy
              score = score + 1
            end

            if ball_y > height
              lives = lives - 1
              ball_x = rand(width - 30)
              ball_y = 0
              dy = 3
            end
          end

          clear do
            background "#123"
            nostroke
            fill "#fc0"
            oval ball_x, ball_y, 30, 30
            fill "#0cf"
            rect bat_x, height - 20, 80, 12
            nofill
            para "Score: " + score.to_s + "    Lives: " + lives.to_s,
              :stroke => white, :margin => 8
            if lives < 1
              para "Game over!", :stroke => "#f66", :size => 28,
                :align => "center", :margin_top => 90
            end
          end
        end
      end
    CODE
    para "That is a real game, in forty lines. Now make it yours: speed the ball ",
         "up every time you catch it, make the bat narrower as the score climbs, ",
         "or give yourself ten lives while you practise."
  end

end
