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
        @wavesfight_queues = Hash.new { |hash, key| hash[key] = [] }
      end

      def run
        cert, key, chain = load_or_create_cert

        ctx = OpenSSL::SSL::SSLContext.new
        ctx.cert = cert
        ctx.key  = key
        ctx.extra_chain_cert = chain unless chain.empty?

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
        request = read_queue_request(client)
        unless request
          client.close
          return
        end
        peer = begin
          client.peeraddr[2]
        rescue StandardError
          "unknown"
        end
        if request[:mode] == :wavesfight
          enqueue_wavesfight_player(client, peer, request)
        else
          enqueue_pvp_player(client, peer, request[:team_size])
        end
      end

      def enqueue_pvp_player(client, peer, team_size)
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

      def enqueue_wavesfight_player(client, peer, request)
        mission_id = request[:mission_id]
        difficulty = request[:difficulty]
        key = [mission_id, difficulty]
        puts "Player connected from #{peer}, queued for wavesfight #{mission_id} diff=#{difficulty}"

        match_players = nil
        @queue_mutex.synchronize do
          @wavesfight_queues[key] << { socket: client, peer: peer }
          if @wavesfight_queues[key].size >= 2
            match_players = @wavesfight_queues[key].shift(2)
          else
            waiting = @wavesfight_queues[key].size
            puts "Queue wavesfight #{mission_id}: #{waiting}/2"
          end
        end
        return unless match_players

        Thread.new { run_wavesfight_match(mission_id, difficulty, match_players) }
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

            if msg[:mode].to_s == "wavesfight"
              return {
                mode: :wavesfight,
                mission_id: msg[:mission_id].to_s,
                difficulty: [[msg[:difficulty].to_i, 0].max, Enemy::Base::DIFFICULTIES.size - 1].min
              }
            end

            team_size = msg[:team_size].to_i
            return { mode: :pvp, team_size: TEAM_SIZES.include?(team_size) ? team_size : 1 }
          end
        end

        { mode: :pvp, team_size: 1 }
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

      def run_wavesfight_match(mission_id, difficulty, players)
        mission_klass = Mission::Base.wavesfight.find { |klass| klass.new.id == mission_id }
        unless mission_klass
          players.each { |player| player[:socket].close rescue nil }
          return
        end

        mission = mission_klass.new
        map = mission.build_map
        spawns = wavesfight_spawns(map, mission.spawn)
        roster = players.each_with_index.map do |entry, idx|
          spawn = spawns[idx]
          {
            id: idx,
            socket: entry[:socket],
            peer: entry[:peer],
            buf: +"",
            x: spawn[0],
            y: spawn[1],
            angle: spawn[2],
            shield: Config::SHIELD_MAX,
            health: Config::HEALTH_MAX,
            last_damage: -Config::SHIELD_DELAY,
            weapon: :ar,
            ammo: 60,
            fire_flash: 0,
            alive: true
          }
        end

        session = {
          mission: mission,
          map: map,
          difficulty: difficulty,
          wave: 0,
          enemies: [],
          projectiles: [],
          clock: Process.clock_gettime(Process::CLOCK_MONOTONIC)
        }
        start_wavesfight_wave(session, roster)

        roster.each do |player|
          send_json(player[:socket], {
                      t: "wavesfight_start",
                      id: player[:id],
                      map: mission.map_data,
                      mission: mission.name,
                      players: roster.map { |entry| { id: entry[:id], spawn: [entry[:x], entry[:y], entry[:angle]] } }
                    })
        end

        last_broadcast = session[:clock]
        loop do
          now = Process.clock_gettime(Process::CLOCK_MONOTONIC)
          dt = now - session[:clock]
          session[:clock] = now

          sockets = roster.filter_map do |player|
            sock = player[:socket]
            sock unless sock.closed?
          rescue IOError
            nil
          end
          break if sockets.empty?

          readable, = IO.select(sockets, nil, nil, 0.01)
          if readable
            readable.each do |sock|
              player = roster.find { |entry| entry[:socket] == sock }
              next unless player

              begin
                player[:buf] << sock.read_nonblock(4096)
                consume_wavesfight_messages(roster, session, player)
              rescue IO::WaitReadable
                next
              rescue EOFError, Errno::ECONNRESET, Errno::EPIPE, IOError, OpenSSL::SSL::SSLError
                broadcast(roster, { t: "match_end", reason: "disconnect", player_id: player[:id] }, except: player[:id])
                close_players(roster)
                return
              end
            end
          end

          update_wavesfight_session(roster, session, dt)
          if all_wavesfight_players_dead?(roster)
            broadcast(roster, { t: "match_end", reason: "defeat", wave: session[:wave] })
            close_players(roster)
            return
          end

          if now - last_broadcast >= 1.0 / 15.0
            broadcast_wavesfight_world(roster, session)
            last_broadcast = now
          end
        end
      end

      def consume_wavesfight_messages(roster, session, player)
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
            player[:x] = msg[:x]
            player[:y] = msg[:y]
            player[:angle] = msg[:a]
            player[:weapon] = msg[:w]&.to_sym || player[:weapon]
            player[:ammo] = msg[:am] if msg.key?(:am)
            player[:fire_flash] = msg[:ff] || 0
          when "fire"
            player[:fire_flash] = 4
            process_wavesfight_fire(session, player)
          end
        end
      end

      def update_wavesfight_session(roster, session, dt)
        roster.each do |player|
          player[:fire_flash] -= 1 if player[:fire_flash].to_i > 0
          next unless player[:alive]

          if player[:shield] < Config::SHIELD_MAX && (session[:clock] - player[:last_damage]) >= Config::SHIELD_DELAY
            player[:shield] = [player[:shield] + Config::SHIELD_REGEN * dt, Config::SHIELD_MAX].min
          end
          if player[:shield] >= Config::SHIELD_MAX && player[:health] < Config::HEALTH_MAX
            player[:health] = [player[:health] + Config::SHIELD_REGEN * dt, Config::HEALTH_MAX].min
          end
        end

        session[:enemies].each do |enemy|
          next unless enemy.alive

          target = roster.select { |player| player[:alive] }
                         .min_by { |player| (player[:x] - enemy.x)**2 + (player[:y] - enemy.y)**2 }
          next unless target

          enemy.update(dt, Struct.new(:x, :y).new(target[:x], target[:y]), session[:projectiles], session[:map],
                       session[:clock], difficulty: session[:difficulty])
        end

        session[:projectiles].reject! do |projectile|
          projectile.update(dt)
          if projectile.hit_wall?(session[:map])
            true
          else
            target = roster.find { |player| player[:alive] && projectile.hit_player?(player[:x], player[:y]) }
            if target
              dmg = enemy_damage(projectile.type)
              apply_wavesfight_damage(target, dmg, session[:clock])
              send_json(target[:socket], { t: "hit", d: dmg })
              true
            else
              false
            end
          end
        end

        if session[:enemies].all? { |enemy| !enemy.alive }
          start_wavesfight_wave(session, roster)
          broadcast(roster, { t: "wave_start", wave: session[:wave], difficulty: session[:difficulty] })
        end
      end

      def process_wavesfight_fire(session, player)
        weapon = Weapon::Base.build(player[:weapon] || :ar, player[:ammo])
        dx = Math.cos(player[:angle])
        dy = Math.sin(player[:angle])
        best = nil
        best_dot = Float::INFINITY

        session[:enemies].each do |enemy|
          next unless enemy.alive

          ox = enemy.x - player[:x]
          oy = enemy.y - player[:y]
          dot = ox * dx + oy * dy
          next if dot < 0.1

          perp = (ox * (-dy) + oy * dx).abs
          next if perp > weapon.hit_width
          next unless session[:map].line_of_sight?(player[:x], player[:y], enemy.x, enemy.y)
          next unless dot < best_dot

          best = enemy
          best_dot = dot
        end
        return unless best

        best.take_damage(1)
      end

      def enemy_damage(type)
        enemy_klass = Enemy::Base.registry[type]
        enemy_klass ? enemy_klass.allocate.send(:damage) : 10
      end

      def apply_wavesfight_damage(player, amount, clock)
        if player[:shield] > 0
          overflow = amount - player[:shield]
          player[:shield] = [player[:shield] - amount, 0].max
          player[:health] = [player[:health] - [overflow, 0].max, 0].max if player[:shield] == 0
        else
          player[:health] = [player[:health] - amount, 0].max
        end

        player[:last_damage] = clock
        player[:alive] = false if player[:health] <= 0
      end

      def all_wavesfight_players_dead?(roster)
        roster.none? { |player| player[:alive] }
      end

      def broadcast_wavesfight_world(roster, session)
        msg = {
          t: "world",
          wave: session[:wave],
          difficulty: session[:difficulty],
          players: roster.map do |player|
            {
              id: player[:id], x: player[:x], y: player[:y], a: player[:angle],
              s: player[:shield], h: player[:health], w: player[:weapon], am: player[:ammo],
              ff: player[:fire_flash], alive: player[:alive]
            }
          end,
          enemies: session[:enemies].map do |enemy|
            {
              id: enemy.object_id, x: enemy.x, y: enemy.y, type: enemy.sprite_id,
              hp: enemy.hp, max_hp: enemy.max_hp, alive: enemy.alive
            }
          end,
          projectiles: session[:projectiles].map { |projectile| { x: projectile.x, y: projectile.y, type: projectile.type } },
          drops: []
        }
        broadcast(roster, msg)
      end

      def start_wavesfight_wave(session, roster = nil)
        session[:wave] += 1
        session[:difficulty] = [session[:difficulty], 1 + ((session[:wave] - 1) / 3)].max
        session[:difficulty] = [session[:difficulty], Enemy::Base::DIFFICULTIES.size - 1].min
        session[:enemies] = build_wavesfight_enemies(session[:mission], session[:wave], session[:difficulty])
        session[:projectiles].clear
        replenish_wavesfight_roster(roster, session) if roster && session[:wave] > 1
      end

      def replenish_wavesfight_roster(roster, session)
        roster.each do |player|
          player[:shield] = [player[:shield] + 35.0, Config::SHIELD_MAX].min
          player[:health] = [player[:health] + 20.0, Config::HEALTH_MAX].min
          player[:last_damage] = session[:clock] - Config::SHIELD_DELAY
          player[:alive] = true
        end
      end

      def build_wavesfight_enemies(mission, wave, difficulty_index)
        enemies = mission.build_enemies(difficulty_index)
        bonus_count = (wave - 1) * 2
        enemies + Enemy::Base.generate_extras(mission.enemy_defs, bonus_count, difficulty_index)
      end

      def wavesfight_spawns(map, spawn)
        x, y, angle = spawn
        spawns = [[x, y, angle]]
        offsets = [
          [1.0, 0.0], [-1.0, 0.0], [0.0, 1.0], [0.0, -1.0],
          [1.0, 1.0], [1.0, -1.0], [-1.0, 1.0], [-1.0, -1.0]
        ]
        offsets.each do |dx, dy|
          nx = x + dx
          ny = y + dy
          next if map.blocked?(nx, ny)

          spawns << [nx, ny, angle]
          break
        end
        spawns
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
        cert_file = ENV.fetch("TERMFRONT_TLS_CERT_FILE", "termfront_server.crt")
        key_file  = ENV.fetch("TERMFRONT_TLS_KEY_FILE", "termfront_server.key")

        if File.exist?(cert_file) && File.exist?(key_file)
          certs = OpenSSL::X509::Certificate.load(File.read(cert_file))
          certs = [certs] unless certs.is_a?(Array)
          cert = certs.first
          chain = certs.drop(1)
          key  = OpenSSL::PKey::RSA.new(File.read(key_file))
          puts "Loaded existing certificate."
        else
          cert, key = generate_self_signed_cert
          File.write(cert_file, cert.to_pem)
          File.write(key_file, key.to_pem)
          puts "Generated new self-signed certificate."
          chain = []
        end
        [cert, key, chain]
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
