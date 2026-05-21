# frozen_string_literal: true

module Termfront
  module TerminalOutput
    module_function
    ANSI_PATTERN = /\e\[[0-9;]*[A-Za-z]/.freeze

    def sync_updates?
      ENV.fetch("TERMFRONT_SYNC_UPDATES", "1") == "1"
    end

    def begin_frame(home: false, clear: false)
      buf = +""
      buf << "\e[?2026h" if sync_updates?
      buf << "\e[H" if home
      buf << "\e[2J" if clear
      buf
    end

    def end_frame
      sync_updates? ? "\e[?2026l" : ""
    end

    def fit_ansi(text, width)
      visible = 0
      out = +""
      index = 0

      while index < text.length && visible < width
        if (match = ANSI_PATTERN.match(text, index)) && match.begin(0) == index
          out << match[0]
          index = match.end(0)
          next
        end

        char = text[index]
        out << char
        visible += 1
        index += 1
      end

      out << "\e[0m" if out.include?("\e[")
      out << (" " * (width - visible)) if visible < width
      out
    end

    def write_all(io, data)
      total = 0
      bytes = data.bytesize

      while total < bytes
        begin
          written = io.syswrite(data.byteslice(total, bytes - total))
          total += written
        rescue IO::WaitWritable
          IO.select(nil, [io])
        end
      end

      total
    end
  end
end
