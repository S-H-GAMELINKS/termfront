# frozen_string_literal: true

module Termfront
  module TerminalOutput
    module_function

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
