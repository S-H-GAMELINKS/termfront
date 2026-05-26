# frozen_string_literal: true

module Termfront
  class AsyncWriter
    def initialize(io)
      @io = io
      @queue = Queue.new
      @closed = false
      @thread = Thread.new do
        Thread.current.report_on_exception = false
        while (data = @queue.pop)
          begin
            TerminalOutput.write_all(@io, data)
          rescue IOError, Errno::EBADF, Errno::EPIPE
            break
          end
        end
      end
    end

    def syswrite(data)
      raise IOError, "writer closed" if @closed

      @queue.clear if @queue.size >= 1
      @queue.push(data)
      data.bytesize
    end

    def winsize
      @io.winsize
    end

    def raw(&block)
      @io.raw(&block)
    end

    def close
      return if @closed

      @closed = true
      @queue.push(nil)
      @thread.join
    end
  end
end
