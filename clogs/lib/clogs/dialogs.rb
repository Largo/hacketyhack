# frozen_string_literal: true

require_relative "ui"

module Clogs
  # Shoes' modal helpers.
  #
  # libui gives us exactly two dialogs of its own -- a message box and a file
  # picker -- and neither can ask a question. `ask` and `confirm` are therefore
  # built as small real windows made of native libui controls, run on a nested
  # `uiMainStep` loop so they block the caller the way Shoes expects.
  module Dialogs
    module_function

    def alert(parent, message)
      UI::L.msg_box(parent, "", message.to_s)
      nil
    end

    def error(parent, message)
      UI::L.msg_box_error(parent, "", message.to_s)
      nil
    end

    def open_file(parent)
      ptr = UI::L.open_file(parent)
      pointer_to_string(ptr)
    end

    def save_file(parent)
      ptr = UI::L.save_file(parent)
      pointer_to_string(ptr)
    end

    def open_folder(parent)
      return nil unless UI::L.respond_to?(:open_folder)

      pointer_to_string(UI::L.open_folder(parent))
    end

    def pointer_to_string(ptr)
      return nil if ptr.nil? || ptr.null?

      str = ptr.to_s
      UI::L.free_text(ptr)
      str.empty? ? nil : str
    end

    # A one-line text prompt. Returns the string, or nil if cancelled.
    def ask(parent, message, secret: false)
      result = nil
      modal(parent, "", 320, 100) do |win, box, finish|
        UI::L.box_append(box, label(message.to_s), 0)
        entry = secret ? UI::L.new_password_entry : UI::L.new_entry
        UI::L.box_append(box, entry, 0)

        buttons = UI::L.new_horizontal_box
        UI::L.box_set_padded(buttons, 1)
        ok = UI::L.new_button("OK")
        cancel = UI::L.new_button("Cancel")
        UI::L.box_append(buttons, ok, 1)
        UI::L.box_append(buttons, cancel, 1)
        UI::L.box_append(box, buttons, 0)

        UI::L.button_on_clicked(ok) do
          result = UI::L.entry_text(entry).to_s
          finish.call
          0
        end
        UI::L.button_on_clicked(cancel) do
          result = nil
          finish.call
          0
        end
        _ = win
      end
      result
    end

    # A yes/no question. Returns true or false.
    def confirm(parent, question)
      result = false
      modal(parent, "", 320, 90) do |_win, box, finish|
        UI::L.box_append(box, label(question.to_s), 0)
        buttons = UI::L.new_horizontal_box
        UI::L.box_set_padded(buttons, 1)
        yes = UI::L.new_button("OK")
        no = UI::L.new_button("Cancel")
        UI::L.box_append(buttons, yes, 1)
        UI::L.box_append(buttons, no, 1)
        UI::L.box_append(box, buttons, 0)

        UI::L.button_on_clicked(yes) do
          result = true
          finish.call
          0
        end
        UI::L.button_on_clicked(no) do
          result = false
          finish.call
          0
        end
      end
      result
    end

    def label(text)
      UI::L.new_label(text)
    end

    # Run a modal window on a nested event loop. libui does not allow uiMain to
    # be re-entered, but stepping it by hand is fine and is how a blocking
    # dialog has to work here.
    def modal(parent, title, width, height)
      win = UI::L.new_window(title, width, height, 0)
      UI::L.window_set_margined(win, 1)
      box = UI::L.new_vertical_box
      UI::L.box_set_padded(box, 1)
      UI::L.window_set_child(win, box)

      done = false
      finish = -> { done = true }
      UI::L.window_on_closing(win) do
        done = true
        0
      end

      yield win, box, finish

      UI::L.control_show(win)
      # This loop is its own, separate event pump -- CLOGS_EXIT_AFTER_MS's
      # usual enforcement runs from Clogs::App's own paint callback, which
      # never gets a turn while a modal dialog owns the loop. Without this, a
      # sample that blocks on ask/confirm/alert with nobody there to answer
      # (any headless test) would hang until the test harness's own outer
      # timeout, rather than the deadline the harness actually asked for.
      deadline = test_deadline
      UI::L.main_step(1) until done || (deadline && Process.clock_gettime(Process::CLOCK_MONOTONIC) >= deadline)
      UI::L.control_destroy(win)
      _ = parent
    end

    def test_deadline
      ms = ENV["CLOGS_EXIT_AFTER_MS"]&.to_i
      return nil unless ms&.positive?

      Process.clock_gettime(Process::CLOCK_MONOTONIC) + ms / 1000.0
    end
  end
end
