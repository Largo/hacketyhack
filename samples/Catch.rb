#
# Catch! Move the bat with the mouse and keep the ball off the floor.
# Built step by step in the "Make Something Move" lesson.
#
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
