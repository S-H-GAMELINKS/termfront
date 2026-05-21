# frozen_string_literal: true

require "socket"
require "openssl"
require "json"

module Termfront
  module Network
    class Server
      TEAM_SIZES = [1, 2, 4].freeze
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
      PVP_SPAWN_CANDIDATES = [
        [2.5, 2.5, 0.0],
        [2.5, 11.5, 0.0],
        [5.5, 5.5, 0.0],
        [4.5, 9.5, 0.0],
        [17.5, 11.5, Math::PI],
        [17.5, 2.5, Math::PI],
        [14.5, 8.5, Math::PI],
        [15.5, 4.5, Math::PI]
      ].freeze

      def initialize(port: Config::PVP_PORT)
        @port = port
        @queue_mutex = Mutex.new
        @queues = TEAM_SIZES.to_h { |team_size| [team_size, []] }
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
          begin
            client = ssl_server.accept
            configure_client(client)
            enqueue_player(client)
          rescue OpenSSL::SSL::SSLError => e
            puts "SSL handshake failed: #{e.message}"
          rescue StandardError => e
            puts "Accept error: #{e.message}"
          end
        end
      end

      private

      def configure_client(client)
        client.sync = true
        return unless client.respond_to?(:to_io)

        io = client.to_io
        io.setsockopt(Socket::IPPROTO_TCP, Socket::TCP_NODELAY, 1) if io.respond_to?(:setsockopt)
      end

      def enqueue_player(client)
        team_size = read_queue_request(client)
        unless team_size
          client.close
          return
        end
        peer = begin
          client.peeraddr[2]
        rescue StandardError
          "unknown"
        end
        puts "Player connected from #{peer}, queued for #{team_size}v#{team_size}"

        match_players = nil
        @queue_mutex.synchronize do
          @queues[team_size] << { socket: client, peer: peer }
          required = team_size * 2
          if @queues[team_size].size >= required
            match_players = @queues[team_size].shift(required)
          else
            waiting = @queues[team_size].size
            puts "Queue #{team_size}v#{team_size}: #{waiting}/#{required}"
          end
        end
        return unless match_players

        Thread.new { run_match(team_size, match_players) }
      end

      def read_queue_request(client)
        buf = +""
        deadline = Time.now + 15

        while Time.now < deadline
          readable, = IO.select([client], nil, nil, 0.5)
          next unless readable

          begin
            buf << client.read_nonblock(4096)
          rescue IO::WaitReadable
            next
          end

          while (nl = buf.index("\n"))
            line = buf.slice!(0, nl + 1)
            begin
              msg = JSON.parse(line, symbolize_names: true)
            rescue JSON::ParserError
              next
            end
            next unless msg[:t] == "queue"

            team_size = msg[:team_size].to_i
            return TEAM_SIZES.include?(team_size) ? team_size : 1
          end
        end

        1
      rescue EOFError, Errno::ECONNRESET, Errno::EPIPE, IOError, OpenSSL::SSL::SSLError
        nil
      end

      def run_match(team_size, players)
        total_players = team_size * 2
        puts "Match starting: #{team_size}v#{team_size} (#{total_players} players)"

        roster = players.each_with_index.map do |entry, idx|
          team = idx < team_size ? 0 : 1
          {
            id: idx,
            team: team,
            socket: entry[:socket],
            peer: entry[:peer],
            spawn: pvp_spawns[idx],
            buf: +"",
            alive: true
          }
        end

        roster.each do |player|
          send_json(player[:socket], {
                      t: "start",
                      id: player[:id],
                      team: player[:team],
                      team_size: team_size,
                      map: PVP_MAP,
                      players: roster.map { |p| { id: p[:id], team: p[:team], spawn: p[:spawn] } }
                    })
        end

        loop do
          sockets = roster.filter_map do |player|
            sock = player[:socket]
            sock unless sock.closed?
          rescue IOError
            nil
          end
          break if sockets.empty?

          readable, = IO.select(sockets, nil, nil, 0.5)
          next unless readable

          readable.each do |sock|
            player = roster.find { |entry| entry[:socket] == sock }
            next unless player

            begin
              player[:buf] << sock.read_nonblock(4096)
              consume_messages(roster, player)
            rescue IO::WaitReadable
              next
            rescue EOFError, Errno::ECONNRESET, Errno::EPIPE, IOError, OpenSSL::SSL::SSLError
              puts "Player #{player[:id]} disconnected from #{player[:peer]}"
              broadcast(roster, { t: "match_end", reason: "disconnect", player_id: player[:id] }, except: player[:id])
              close_players(roster)
              puts "Match aborted."
              return
            end
          end

          winner = winning_team(roster)
          next if winner.nil?

          broadcast(roster, { t: "match_end", reason: "team_eliminated", winner: winner })
          close_players(roster)
          puts "Match ended. Team #{winner} won."
          return
        end
      end

      def consume_messages(roster, player)
        while (nl = player[:buf].index("\n"))
          line = player[:buf].slice!(0, nl + 1)
          begin
            msg = JSON.parse(line, symbolize_names: true)
          rescue JSON::ParserError
            next
          end

          case msg[:t]
          when "ping"
            send_json(player[:socket], { t: "pong", ts: msg[:ts] })
          when "state"
            broadcast(roster, msg.merge(from: player[:id]), except: player[:id])
          when "hit"
            route_hit(roster, player, msg)
          when "dead"
            player[:alive] = false
            broadcast(roster, { t: "dead", from: player[:id] }, except: player[:id])
          end
        end
      end

      def route_hit(roster, attacker, msg)
        target_id = msg[:target].to_i
        target = roster.find { |player| player[:id] == target_id }
        return unless target
        return unless target[:alive] && attacker[:alive]
        return if target[:team] == attacker[:team]

        send_json(target[:socket], { t: "hit", from: attacker[:id], d: msg[:d] || Config::PVP_HIT_DMG })
      end

      def winning_team(roster)
        alive_teams = roster.select { |player| player[:alive] }.map { |player| player[:team] }.uniq
        return nil unless alive_teams.size == 1

        alive_teams.first
      end

      def broadcast(roster, msg, except: nil)
        roster.each do |player|
          next if player[:id] == except

          send_json(player[:socket], msg)
        end
      end

      def send_json(socket, msg)
        socket.write(JSON.generate(msg) + "\n")
      rescue Errno::EPIPE, Errno::ECONNRESET, IOError, OpenSSL::SSL::SSLError
        nil
      end

      def close_players(roster)
        roster.each do |player|
          player[:socket].close
        rescue StandardError
          nil
        end
      end

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

      def pvp_spawns
        @pvp_spawns ||= begin
          map = Map.new(PVP_MAP)
          PVP_SPAWN_CANDIDATES.each do |spawn|
            x, y, = spawn
            raise "Invalid PvP spawn #{spawn.inspect}" if map.blocked?(x, y)
          end
          PVP_SPAWN_CANDIDATES
        end
      end
    end
  end
end
