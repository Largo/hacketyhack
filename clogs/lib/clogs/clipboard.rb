# frozen_string_literal: true

module Clogs
  # libui has no clipboard API at all, so Clogs shells out to whatever the
  # platform provides. If nothing is available, copy and paste quietly do
  # nothing rather than raising in the middle of someone's keystroke.
  module Clipboard
    module_function

    def read
      cmd = read_command
      return @fallback.to_s unless cmd

      out = `#{cmd} 2>/dev/null`
      $?.success? ? out : @fallback.to_s
    rescue StandardError
      @fallback.to_s
    end

    def write(text)
      @fallback = text
      cmd = write_command
      return unless cmd

      IO.popen(cmd, "w") { |io| io.write(text) }
    rescue StandardError
      nil
    end

    def read_command
      @read_command ||= case RUBY_PLATFORM
      when /darwin/ then "pbpaste"
      when /mingw|mswin/ then "powershell -command Get-Clipboard"
      else
        if system("which xclip > /dev/null 2>&1")
          "xclip -selection clipboard -o"
        elsif system("which xsel > /dev/null 2>&1")
          "xsel --clipboard --output"
        end
      end
    end

    def write_command
      @write_command ||= case RUBY_PLATFORM
      when /darwin/ then "pbcopy"
      when /mingw|mswin/ then "clip"
      else
        if system("which xclip > /dev/null 2>&1")
          "xclip -selection clipboard -i"
        elsif system("which xsel > /dev/null 2>&1")
          "xsel --clipboard --input"
        end
      end
    end
  end
end
