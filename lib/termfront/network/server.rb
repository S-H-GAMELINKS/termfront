# frozen_string_literal: true

require "socket"
require "openssl"
require "json"

module Termfront
  module Network
    class Server
      PVP_MAP = [
        "####################",
        "#........##........#",
        "#........##........#",
        "#..................#",
        "#..##........##....#",
        "#..##........##....#",
        "#..................#",
        "#..................#",
        "#....##........##..#",
        "#....##........##..#",
        "#..................#",
        "#........##........#",
        "#........##........#",
        "####################"
      ].freeze
      PVP_SPAWNS = [[2.5, 2.5, 0.0], [17.5, 11.5, Math::PI]].freeze

      def initialize(port: Config::PVP_PORT)
        @port = port
      end

      def run
        cert, key = load_or_create_cert

        ctx = OpenSSL::SSL::SSLContext.new
        ctx.cert = cert
        ctx.key  = key

        tcp_server = TCPServer.new("0.0.0.0", @port)
        ssl_server = OpenSSL::SSL::SSLServer.new(tcp_server, ctx)
        ssl_server.start_immediately = true

        puts "Termfront PvP server listening on 0.0.0.0:#{@port}"

        loop do
          players = []
          bufs = [+"", +""]

          puts "\nWaiting for 2 players..."

          while players.size < 2
            begin
              client = ssl_server.accept
              client.sync = true
              if client.respond_to?(:to_io)
                io = client.to_io
                io.setsockopt(Socket::IPPROTO_TCP, Socket::TCP_NODELAY, 1) if io.respond_to?(:setsockopt)
              end
              players << client
              puts "Player #{players.size - 1} connected from #{begin
                client.peeraddr[2]
              rescue StandardError
                "unknown"
              end}"
            rescue OpenSSL::SSL::SSLError => e
              puts "SSL handshake failed: #{e.message}"
              next
            rescue StandardError => e
              puts "Accept error: #{e.message}"
              next
            end
          end

          2.times do |i|
            msg = {
              t: "start",
              id: i,
              map: PVP_MAP,
              spawn: PVP_SPAWNS[i],
              opp_spawn: PVP_SPAWNS[1 - i]
            }
            players[i].write(JSON.generate(msg) + "\n")
          end
          puts "Match started!"

          running = true
          while running
            readable, = IO.select(players.select { |p| !p.closed? }, nil, nil, 0.5)
            next unless readable

            readable.each do |sock|
              idx = players.index(sock)
              next unless idx

              other = 1 - idx

              begin
                data = sock.read_nonblock(4096)
                bufs[idx] << data

                while (nl = bufs[idx].index("\n"))
                  line = bufs[idx].slice!(0, nl + 1)
                  begin
                    msg = JSON.parse(line, symbolize_names: true)
                  rescue JSON::ParserError
                    next
                  end

                  if msg[:t] == "ping"
                    sock.write(JSON.generate({ t: "pong", ts: msg[:ts] }) + "\n")
                  else
                    players[other].write(line) unless players[other].closed?
                  end
                end
              rescue EOFError, Errno::ECONNRESET, Errno::EPIPE, IOError, OpenSSL::SSL::SSLError
                puts "Player #{idx} disconnected."
                running = false
              end
            end
          end

          players.each do |p|
            p.close
          rescue StandardError
            nil
          end
          puts "Match ended. Returning to lobby."
        end
      end

      private

      def generate_self_signed_cert
        key = OpenSSL::PKey::RSA.new(2048)
        cert = OpenSSL::X509::Certificate.new
        cert.version = 2
        cert.serial = rand(1 << 64)
        cert.subject = OpenSSL::X509::Name.parse("/CN=termfront-pvp")
        cert.issuer = cert.subject
        cert.public_key = key.public_key
        cert.not_before = Time.now
        cert.not_after = Time.now + 365 * 24 * 60 * 60
        cert.sign(key, OpenSSL::Digest.new("SHA256"))
        [cert, key]
      end

      def load_or_create_cert
        cert_file = "termfront_server.crt"
        key_file  = "termfront_server.key"

        if File.exist?(cert_file) && File.exist?(key_file)
          cert = OpenSSL::X509::Certificate.new(File.read(cert_file))
          key  = OpenSSL::PKey::RSA.new(File.read(key_file))
          puts "Loaded existing certificate."
        else
          cert, key = generate_self_signed_cert
          File.write(cert_file, cert.to_pem)
          File.write(key_file, key.to_pem)
          puts "Generated new self-signed certificate."
        end
        [cert, key]
      end
    end
  end
end
