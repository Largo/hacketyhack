# frozen_string_literal: true

require "fox16"

module Clogs
  # Shoes' `alert`, `confirm`, `ask` and the file pickers.
  #
  # The libui backend has to build `ask` out of a window and a nested event
  # loop of its own, because libui has no input dialog. FOX ships all four as
  # native modal dialogs, so this is the one place where the FOX backend is
  # simply shorter than the libui one.
  module Dialogs
    class << self
      def alert(window, message)
        Fox::FXMessageBox.information(owner(window), Fox::MBOX_OK, "Shoes", message.to_s)
        nil
      end

      def confirm(window, message)
        Fox::FXMessageBox.question(owner(window), Fox::MBOX_YES_NO, "Shoes", message.to_s) ==
          Fox::MBOX_CLICKED_YES
      end

      def ask(window, message)
        Fox::FXInputDialog.getString("", owner(window), "Shoes", message.to_s)
      end

      def open_file(window)
        blank_to_nil(Fox::FXFileDialog.getOpenFilename(owner(window), "Open File", Dir.pwd))
      end

      def save_file(window)
        blank_to_nil(Fox::FXFileDialog.getSaveFilename(owner(window), "Save File", Dir.pwd))
      end

      def open_folder(window)
        blank_to_nil(Fox::FXFileDialog.getOpenDirectory(owner(window), "Open Folder", Dir.pwd))
      end

      private

      # Shoes 3 let a dialog be raised before any window existed -- Hackety
      # Hack's own Guessing Game sample is a bare ask/alert loop. FOX will
      # parent a dialog to the application itself in that case.
      def owner(window)
        window || App.fox_app
      end

      def blank_to_nil(value)
        value.nil? || value.empty? ? nil : value
      end
    end
  end
end
