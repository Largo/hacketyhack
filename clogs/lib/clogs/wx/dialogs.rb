# frozen_string_literal: true

require "wx"

module Clogs
  # Shoes' `alert`, `confirm`, `ask` and the file pickers, all native.
  module Dialogs
    class << self
      def alert(window, message)
        Wx::MessageDialog.new(window, message.to_s, "Shoes", Wx::OK | Wx::ICON_INFORMATION)
          .show_modal
        nil
      end

      def confirm(window, message)
        Wx::MessageDialog.new(window, message.to_s, "Shoes", Wx::YES_NO | Wx::ICON_QUESTION)
          .show_modal == Wx::ID_YES
      end

      def ask(window, message)
        dialog = Wx::TextEntryDialog.new(window, message.to_s, "Shoes", "")
        dialog.show_modal == Wx::ID_OK ? dialog.get_value : nil
      end

      def open_file(window)
        file_dialog(window, "Open File", Wx::FD_OPEN | Wx::FD_FILE_MUST_EXIST)
      end

      def save_file(window)
        file_dialog(window, "Save File", Wx::FD_SAVE | Wx::FD_OVERWRITE_PROMPT)
      end

      def open_folder(window)
        dialog = Wx::DirDialog.new(window, "Open Folder", Dir.pwd)
        dialog.show_modal == Wx::ID_OK ? dialog.get_path : nil
      end

      private

      def file_dialog(window, title, style)
        dialog = Wx::FileDialog.new(window, title, Dir.pwd, "", "*", style)
        dialog.show_modal == Wx::ID_OK ? dialog.get_path : nil
      end
    end
  end
end
