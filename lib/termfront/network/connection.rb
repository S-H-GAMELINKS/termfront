# frozen_string_literal: true

require "socket"
require "openssl"
require "json"
require "time"

module Termfront
  module Network
    class Connection
      MAX_MSG_BYTES = 64 * 1024

      PeerInfo = Struct.new(
        :certificate_sha256,
        :public_key_sha256,
        :subject,
        :issuer,
        :not_after,
        keyword_init: true
      )

      attr_reader :rtt
      attr_reader :peer_info

      def initialize
        @sock = nil
        @buf = +""
        @ping_ts = 0
        @rtt = 0
        @peer_info = nil
      end

      def connect(host, port, ca_file: nil)
        tcp = TCPSocket.new(host, port)
        tcp.setsockopt(Socket::IPPROTO_TCP, Socket::TCP_NODELAY, 1)

        ctx = build_ssl_context(ca_file: ca_file)
        @sock = OpenSSL::SSL::SSLSocket.new(tcp, ctx)
        @sock.hostname = host if @sock.respond_to?(:hostname=)
        @sock.sync = true
        @sock.connect
        @sock.post_connection_check(host)
        @peer_info = build_peer_info(@sock.peer_cert)
      rescue StandardError
        tcp&.close
        @sock = nil
        @peer_info = nil
        raise
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

            if @buf.bytesize > MAX_MSG_BYTES
              close
              break
            end

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
        @peer_info = nil
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

      def build_ssl_context(ca_file:)
        ctx = OpenSSL::SSL::SSLContext.new
        ctx.verify_mode = OpenSSL::SSL::VERIFY_PEER
        ctx.verify_hostname = true if ctx.respond_to?(:verify_hostname=)
        ctx.min_version = OpenSSL::SSL::TLS1_2_VERSION
        ctx.cert_store = build_cert_store(ca_file: ca_file)
        ctx
      end

      def build_cert_store(ca_file:)
        store = OpenSSL::X509::Store.new
        store.set_default_paths
        store.add_file(ca_file) if ca_file
        store
      end

      def build_peer_info(cert)
        PeerInfo.new(
          certificate_sha256: OpenSSL::Digest::SHA256.hexdigest(cert.to_der),
          public_key_sha256: OpenSSL::Digest::SHA256.hexdigest(cert.public_key.to_der),
          subject: cert.subject.to_s,
          issuer: cert.issuer.to_s,
          not_after: cert.not_after.utc
        )
      end
    end
  end
end
