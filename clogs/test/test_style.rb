# frozen_string_literal: true

require_relative "test_helper"

class TestStyle < Minitest::Test
  Style = Clogs::Style

  def test_pixel_dimensions
    assert_equal 100, Style.dimension(100, 400)
    assert_nil Style.dimension(nil, 400)
  end

  def test_fractional_dimensions
    assert_equal 200, Style.dimension(0.5, 400)
    assert_equal 200, Style.dimension("50%", 400)
  end

  def test_negative_dimension_is_relative_to_the_parent
    assert_equal 380, Style.dimension(-20, 400)
    assert_equal 0, Style.dimension(-500, 400)
  end

  def test_colors_from_arrays_and_hex
    assert_equal [255, 0, 0, 255], Style.color([255, 0, 0])
    assert_equal [255, 0, 0, 128], Style.color([255, 0, 0, 128])
    assert_equal [255, 0, 0, 255], Style.color("#ff0000")
    assert_equal [255, 0, 0, 255], Style.color("#f00")
  end

  def test_unknown_color_falls_back
    assert_equal [1, 2, 3, 4], Style.color(nil, [1, 2, 3, 4])
  end

  def test_margin_shorthand_and_overrides
    assert_equal [5, 5, 5, 5], Style.margins("margin" => 5)
    assert_equal [1, 2, 3, 4], Style.margins("margin" => [1, 2, 3, 4])
    assert_equal [1, 9, 3, 4], Style.margins("margin" => [1, 2, 3, 4], "margin_top" => 9)
  end
end
