# frozen_string_literal: true

module Termfront
  module TerminalOutput
    module_function

    def begin_frame(home: false, clear: false)
      buf = +""
      buf << "\e[H" if home
      buf << "\e[2J" if clear
      buf
    end

    def end_frame
      ""
    end

    def fit_ansi(text, width)
      out = +""
      visible = 0
      any_ansi = false
      i = 0
      len = text.bytesize
      segment_start = 0

      while i < len
        byte = text.getbyte(i)
        if byte == 0x1B
          out << text.byteslice(segment_start, i - segment_start) if i > segment_start

          esc_start = i
          i += 1
          while i < len
            b = text.getbyte(i)
            i += 1
            break if (b >= 65 && b <= 90) || (b >= 97 && b <= 122)
          end
          out << text.byteslice(esc_start, i - esc_start)
          any_ansi = true
          segment_start = i
        else
          if (byte & 0xC0) != 0x80
            break if visible >= width

            visible += 1
          end
          i += 1
        end
      end

      out << text.byteslice(segment_start, i - segment_start) if i > segment_start
      out << "\e[0m" if any_ansi
      (width - visible).times { out << " " } if visible < width
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
