# frozen_string_literal: true

require_relative "test_helper"

class TestParagraph < Minitest::Test
  def test_tokenize_keeps_trailing_space_with_the_word
    assert_equal ["one ", "two ", "three"], Clogs::Paragraph.tokenize("one two three")
  end

  def test_tokenize_keeps_newlines_as_their_own_token
    assert_equal ["a ", "\n", "b"], Clogs::Paragraph.tokenize("a \nb")
  end

  def test_named_sizes_match_shoes
    assert_equal 48, Clogs::Paragraph::SIZES[:banner]
    assert_equal 12, Clogs::Paragraph::SIZES[:para]
  end

  def style(size: 14)
    Clogs::Paragraph::TextStyle.new(
      family: Clogs.default_font_family, size: size, bold: false, italic: false,
      underline: false, color: [0, 0, 0, 255], bg: nil, owner: :test
    )
  end

  def test_wrapping_produces_multiple_lines
    skip "needs a display" unless ClogsTest.ui_available?

    text = "the quick brown fox jumps over the lazy dog " * 3
    para = Clogs::Paragraph.new([[text, style]], 200)
    ys = para.placed.map(&:y).uniq

    assert_operator ys.size, :>, 1, "expected the text to wrap onto several lines"
    assert_operator para.width, :<=, 200 + 1
  end

  def test_explicit_newline_starts_a_line
    skip "needs a display" unless ClogsTest.ui_available?

    para = Clogs::Paragraph.new([["a\nb", style]], 500)

    assert_equal 2, para.placed.map(&:y).uniq.size
  end

  def test_boxes_for_owner_locate_a_nested_run
    skip "needs a display" unless ClogsTest.ui_available?

    link_style = style.with(owner: :link)
    para = Clogs::Paragraph.new([["before ", style], ["LINK", link_style], [" after", style]], 500)
    boxes = para.boxes_for(:link)

    assert_equal 1, boxes.size
    x, _y, w, _h = boxes.first
    assert_operator x, :>, 0, "the link should not start at the left edge"
    assert_operator w, :>, 0
  end
end
