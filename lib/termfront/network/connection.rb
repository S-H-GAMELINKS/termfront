# frozen_string_literal: true

require "socket"
require "openssl"
require "json"

module Termfront
  module Network
    class Connection
      attr_reader :rtt

      def initialize
        @sock = nil
        @buf = +""
        @ping_ts = 0
        @rtt = 0
      end

      def connect(host, port)
        tcp = TCPSocket.new(host, port)
        tcp.setsockopt(Socket::IPPROTO_TCP, Socket::TCP_NODELAY, 1)

        ctx = OpenSSL::SSL::SSLContext.new
        ctx.verify_mode = OpenSSL::SSL::VERIFY_NONE
        @sock = OpenSSL::SSL::SSLSocket.new(tcp, ctx)
        @sock.hostname = host if @sock.respond_to?(:hostname=)
        @sock.sync = true
        @sock.connect
      end

      def send_msg(hash)
        return unless @sock

        @sock.write(JSON.generate(hash) + "\n")
      rescue Errno::EPIPE, Errno::ECONNRESET, IOError, OpenSSL::SSL::SSLError
        nil
      end

      def receive
        return [] unless @sock

        messages = []

        while IO.select([@sock], nil, nil, 0)
          begin
            data = @sock.read_nonblock(4096)
            @buf << data

            while (nl = @buf.index("\n"))
              line = @buf.slice!(0, nl + 1)
              begin
                msg = JSON.parse(line, symbolize_names: true)
                if msg[:t] == "pong"
                  @rtt = ((clock - @ping_ts) * 1000).to_i if @ping_ts > 0
                else
                  messages << msg
                end
              rescue JSON::ParserError
                next
              end
            end
          rescue IO::WaitReadable
            break
          rescue EOFError, Errno::ECONNRESET, IOError, OpenSSL::SSL::SSLError
            break
          end
        end

        messages
      end

      def close
        begin
          @sock&.close
        rescue StandardError
          nil
        end
        @sock = nil
      end

      def connected?
        !@sock.nil?
      end

      def ping(now)
        @ping_ts = now
        send_msg({ t: "ping", ts: (now * 1000).to_i })
      end

      def socket
        @sock
      end

      private

      def clock
        Process.clock_gettime(Process::CLOCK_MONOTONIC)
      end
    end
  end
end
