# frozen_string_literal: true

require "socket"
require "openssl"
require "json"
require "set"

module Termfront
  module Network
    class Server
      TEAM_SIZES = [1, 2, 4].freeze
      MAX_QUEUE_PER_MODE = 64
      QUEUE_HANDSHAKE_TIMEOUT = 5
      MAX_MSG_BYTES = 16 * 1024
      MATCH_MAX_DURATION = 30 * 60
      MATCH_IDLE_TIMEOUT = 5 * 60
      ALLOWED_MP_WEAPONS = %w[pistol ar shock_pistol shock_rifle].freeze
      INITIAL_OBTAINED_WEAPONS = %i[pistol ar].freeze
      MAX_STATE_DT = 0.5
      POSITION_DELTA_MARGIN = 1.5
      RATE_LIMITS = {
        "state"  => 60,
        "hit"    => 20,
        "fire"   => 20,
        "pickup" => 5,
        "ping"   => 5,
        "dead"   => 5
      }.freeze
      DEFAULT_RATE_LIMIT = 10
      MAX_DROPPED_MSGS = 200
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
        cert, key, chain = load_cert

        ctx = OpenSSL::SSL::SSLContext.new
        ctx.cert = cert
        ctx.key  = key
        ctx.min_version = OpenSSL::SSL::TLS1_2_VERSION
        ctx.extra_chain_cert = chain unless chain.empty?

        tcp_server = TCPServer.new("0.0.0.0", @port)
        ssl_server = OpenSSL::SSL::SSLServer.new(tcp_server, ctx)
        ssl_server.start_immediately = true

        puts "Termfront PvP server listening on 0.0.0.0:#{@port}"

        loop do
          begin
            client = ssl_server.accept
            configure_client(client)
            Thread.new(client) do |c|
              enqueue_player(c)
            rescue StandardError => e
              puts "Connection handler error: #{e.class}"
              begin
                c.close
              rescue StandardError
                nil
              end
            end
          rescue OpenSSL::SSL::SSLError => e
            puts "SSL handshake failed: #{e.class}"
          rescue StandardError => e
            puts "Accept error: #{e.class}"
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
        if request[:mode] == :wavesfight
          enqueue_wavesfight_player(client, request)
        else
          enqueue_pvp_player(client, request[:team_size])
        end
      end

      def enqueue_pvp_player(client, team_size)
        match_players = nil
        rejected = false
        @queue_mutex.synchronize do
          if @queues[team_size].size >= MAX_QUEUE_PER_MODE
            rejected = true
          else
            @queues[team_size] << { socket: client }
            required = team_size * 2
            if @queues[team_size].size >= required
              match_players = @queues[team_size].shift(required)
            else
              waiting = @queues[team_size].size
              puts "Queue #{team_size}v#{team_size}: #{waiting}/#{required}"
            end
          end
        end
        if rejected
          close_socket(client)
          return
        end
        return unless match_players

        Thread.new { supervise_match(match_players) { run_match(team_size, match_players) } }
      end

      def enqueue_wavesfight_player(client, request)
        mission_id = request[:mission_id]
        difficulty = request[:difficulty]
        key = [mission_id, difficulty]

        match_players = nil
        rejected = false
        @queue_mutex.synchronize do
          if @wavesfight_queues[key].size >= MAX_QUEUE_PER_MODE
            rejected = true
          else
            @wavesfight_queues[key] << { socket: client }
            if @wavesfight_queues[key].size >= 2
              match_players = @wavesfight_queues[key].shift(2)
            else
              waiting = @wavesfight_queues[key].size
              puts "Queue wavesfight #{mission_id}: #{waiting}/2"
            end
          end
        end
        if rejected
          close_socket(client)
          return
        end
        return unless match_players

        Thread.new { supervise_match(match_players) { run_wavesfight_match(mission_id, difficulty, match_players) } }
      end

      def close_socket(client)
        client.close
      rescue StandardError
        nil
      end

      def read_queue_request(client)
        buf = +""
        deadline = Time.now + QUEUE_HANDSHAKE_TIMEOUT

        while Time.now < deadline
          readable, = IO.select([client], nil, nil, 0.5)
          next unless readable

          begin
            buf << client.read_nonblock(4096)
          rescue IO::WaitReadable
            next
          end

          return nil if buf.bytesize > MAX_MSG_BYTES

          while (nl = buf.index("\n"))
            line = buf.slice!(0, nl + 1)
            begin
              msg = JSON.parse(line, symbolize_names: true)
            rescue JSON::ParserError
              next
            end
            next unless msg[:t] == "queue"
            return nil unless queue_token_acceptable?(msg)

            if msg[:mode].to_s == "wavesfight"
              mission_id = msg[:mission_id].to_s
              return nil unless wavesfight_mission_ids.include?(mission_id)

              return {
                mode: :wavesfight,
                mission_id: mission_id,
                difficulty: [[msg[:difficulty].to_i, 0].max, Enemy::Base::DIFFICULTIES.size - 1].min
              }
            end

            team_size = msg[:team_size].to_i
            return { mode: :pvp, team_size: TEAM_SIZES.include?(team_size) ? team_size : 1 }
          end
        end

        nil
      rescue EOFError, Errno::ECONNRESET, Errno::EPIPE, IOError, OpenSSL::SSL::SSLError
        nil
      end

      def run_match(team_size, players)
        total_players = team_size * 2
        puts "Match starting: #{team_size}v#{team_size} (#{total_players} players)"

        roster = players.each_with_index.map do |entry, idx|
          team = idx < team_size ? 0 : 1
          spawn = pvp_spawns[idx]
          {
            id: idx,
            team: team,
            socket: entry[:socket],
            spawn: spawn,
            x: spawn[0],
            y: spawn[1],
            angle: spawn[2],
            last_state_at: nil,
            shield: Config::SHIELD_MAX.to_f,
            health: Config::HEALTH_MAX.to_f,
            last_damage: -Config::SHIELD_DELAY,
            weapon: :ar,
            last_hit_at: nil,
            obtained_weapons: Set.new(INITIAL_OBTAINED_WEAPONS),
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

        match_start = Process.clock_gettime(Process::CLOCK_MONOTONIC)
        last_activity = match_start
        last_tick_at = match_start

        loop do
          sockets = roster.filter_map do |player|
            sock = player[:socket]
            sock unless sock.closed?
          rescue IOError
            nil
          end
          break if sockets.empty?

          readable, = IO.select(sockets, nil, nil, 0.5)

          now = Process.clock_gettime(Process::CLOCK_MONOTONIC)
          if (reason = match_timeout_reason(now, match_start, last_activity))
            broadcast(roster, { t: "match_end", reason: reason })
            close_players(roster)
            puts "Match ended (#{reason})."
            return
          end

          dt = now - last_tick_at
          roster.each { |player| regen_player(player, dt, now) }
          last_tick_at = now

          next unless readable

          last_activity = now

          readable.each do |sock|
            player = roster.find { |entry| entry[:socket] == sock }
            next unless player

            begin
              player[:buf] << sock.read_nonblock(4096)
              if player[:buf].bytesize > MAX_MSG_BYTES
                broadcast(roster, { t: "match_end", reason: "disconnect", player_id: player[:id] }, except: player[:id])
                close_players(roster)
                puts "Match aborted."
                return
              end
              if consume_messages(roster, player) == :rate_limit_exceeded
                broadcast(roster, { t: "match_end", reason: "disconnect", player_id: player[:id] }, except: player[:id])
                close_players(roster)
                puts "Match aborted (rate limit)."
                return
              end
            rescue IO::WaitReadable
              next
            rescue EOFError, Errno::ECONNRESET, Errno::EPIPE, IOError, OpenSSL::SSL::SSLError
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

          unless allow_message(player, msg[:t].to_s, Process.clock_gettime(Process::CLOCK_MONOTONIC))
            player[:dropped_msgs] = (player[:dropped_msgs] || 0) + 1
            return :rate_limit_exceeded if player[:dropped_msgs] > MAX_DROPPED_MSGS

            next
          end

          case msg[:t]
          when "ping"
            send_json(player[:socket], { t: "pong", ts: msg[:ts] })
          when "state"
            next unless valid_position?(msg, pvp_map)

            now = Process.clock_gettime(Process::CLOCK_MONOTONIC)
            new_x = msg[:x].to_f
            new_y = msg[:y].to_f
            next unless position_delta_acceptable?(player[:x], player[:y], player[:last_state_at],
                                                  new_x, new_y, now)

            player[:x] = new_x
            player[:y] = new_y
            player[:angle] = msg[:a].to_f
            player[:last_state_at] = now

            if msg.key?(:w)
              weapon = normalize_weapon(msg[:w], player)
              if weapon
                player[:weapon] = weapon
                msg = msg.merge(w: weapon.to_s)
              else
                msg = msg.except(:w)
              end
            end
            if msg.key?(:am)
              ammo = validate_int(msg[:am], min: -1, max: 999)
              msg = ammo ? msg.merge(am: ammo) : msg.except(:am)
            end
            if msg.key?(:ff)
              ff = validate_int(msg[:ff], min: 0, max: 10)
              msg = msg.merge(ff: ff || 0)
            end
            msg = msg.merge(s: player[:shield].round(1), h: player[:health].round(1))
            broadcast(roster, msg.merge(from: player[:id]), except: player[:id])
          when "hit"
            route_hit(roster, player, msg, Process.clock_gettime(Process::CLOCK_MONOTONIC))
          when "dead"
            player[:alive] = false
            broadcast(roster, { t: "dead", from: player[:id] }, except: player[:id])
          end
        end
      end

      def route_hit(roster, attacker, _msg, clock)
        return unless attacker[:alive]

        weapon = Weapon::Base.build(attacker[:weapon] || :ar)
        return if attacker[:last_hit_at] && (clock - attacker[:last_hit_at]) < weapon.cooldown

        target = pvp_target_from_raycast(roster, attacker, weapon)
        return unless target

        attacker[:last_hit_at] = clock
        apply_damage_to_player(target, Config::PVP_HIT_DMG, clock)
        send_json(target[:socket],
                  { t: "hit", from: attacker[:id], d: Config::PVP_HIT_DMG,
                    s: target[:shield].round(1), h: target[:health].round(1) })
        broadcast(roster, { t: "dead", from: target[:id] }, except: target[:id]) unless target[:alive]
      end

      def pvp_target_from_raycast(roster, attacker, weapon)
        dx = Math.cos(attacker[:angle])
        dy = Math.sin(attacker[:angle])
        best = nil
        best_dot = Float::INFINITY

        roster.each do |other|
          next if other[:id] == attacker[:id]
          next unless other[:alive]
          next if other[:team] == attacker[:team]

          ox = other[:x] - attacker[:x]
          oy = other[:y] - attacker[:y]
          dot = ox * dx + oy * dy
          next if dot < 0.1

          perp = (ox * (-dy) + oy * dx).abs
          next if perp > weapon.hit_width
          next unless pvp_map.line_of_sight?(attacker[:x], attacker[:y], other[:x], other[:y])
          next unless dot < best_dot

          best = other
          best_dot = dot
        end
        best
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

      def valid_position?(msg, map)
        x = msg[:x]
        y = msg[:y]
        a = msg[:a]
        return false unless x.is_a?(Numeric) && y.is_a?(Numeric) && a.is_a?(Numeric)

        fx = x.to_f
        fy = y.to_f
        fa = a.to_f
        return false unless fx.finite? && fy.finite? && fa.finite?
        return false if fx < 0 || fx >= map.width
        return false if fy < 0 || fy >= map.height

        true
      end

      def validate_int(value, min:, max:)
        return nil unless value.is_a?(Numeric) && value.to_f.finite?

        int = value.to_i
        return nil if int < min || int > max

        int
      end

      def allow_message(player, msg_type, now)
        limit = RATE_LIMITS[msg_type] || DEFAULT_RATE_LIMIT
        buckets = (player[:rate_buckets] ||= {})
        bucket = (buckets[msg_type] ||= { tokens: limit.to_f, last_refill: now })

        elapsed = now - bucket[:last_refill]
        bucket[:tokens] = [bucket[:tokens] + elapsed * limit, limit.to_f].min
        bucket[:last_refill] = now

        return false if bucket[:tokens] < 1.0

        bucket[:tokens] -= 1.0
        true
      end

      def position_delta_acceptable?(prev_x, prev_y, prev_at, new_x, new_y, now)
        dt = if prev_at.nil?
               0.1
             else
               [now - prev_at, MAX_STATE_DT].min
             end
        return true if dt <= 0

        max_step = Config::MOVE_SPEED * dt * POSITION_DELTA_MARGIN
        delta_sq = (new_x - prev_x)**2 + (new_y - prev_y)**2
        delta_sq <= max_step * max_step
      end

      def validate_float(value, min:, max:)
        return nil unless value.is_a?(Numeric) && value.to_f.finite?

        f = value.to_f
        return nil if f < min || f > max

        f
      end

      def expected_pvp_token
        token = ENV["TERMFRONT_PVP_TOKEN"]
        token.nil? || token.empty? ? nil : token
      end

      def queue_token_acceptable?(msg)
        expected = expected_pvp_token
        return true if expected.nil?

        provided = msg[:token]
        return false unless provided.is_a?(String)
        return false unless provided.bytesize == expected.bytesize

        OpenSSL.fixed_length_secure_compare(provided, expected)
      end

      def normalize_weapon(value, player = nil)
        return nil unless value.is_a?(String) || value.is_a?(Symbol)

        name = value.to_s
        return nil unless ALLOWED_MP_WEAPONS.include?(name)

        sym = name.to_sym
        if player && player[:obtained_weapons] && !player[:obtained_weapons].include?(sym)
          return nil
        end

        sym
      end

      def match_timeout_reason(now, match_start, last_activity)
        return "match_ttl" if now - match_start > MATCH_MAX_DURATION
        return "idle" if now - last_activity > MATCH_IDLE_TIMEOUT

        nil
      end

      def supervise_match(match_players)
        yield
      rescue StandardError => e
        puts "Match thread crashed: #{e.class}"
      ensure
        match_players.each do |entry|
          entry[:socket].close
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
            buf: +"",
            x: spawn[0],
            y: spawn[1],
            angle: spawn[2],
            shield: Config::SHIELD_MAX,
            health: Config::HEALTH_MAX,
            last_damage: -Config::SHIELD_DELAY,
            last_state_at: nil,
            weapon: :ar,
            ammo: 60,
            obtained_weapons: Set.new(INITIAL_OBTAINED_WEAPONS),
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
          drops: [],
          next_drop_id: 0,
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

        match_start = session[:clock]
        last_activity = match_start
        last_broadcast = session[:clock]
        loop do
          now = Process.clock_gettime(Process::CLOCK_MONOTONIC)
          dt = now - session[:clock]
          session[:clock] = now

          if (reason = match_timeout_reason(now, match_start, last_activity))
            broadcast(roster, { t: "match_end", reason: reason })
            close_players(roster)
            return
          end

          sockets = roster.filter_map do |player|
            sock = player[:socket]
            sock unless sock.closed?
          rescue IOError
            nil
          end
          break if sockets.empty?

          readable, = IO.select(sockets, nil, nil, 0.01)
          if readable
            last_activity = now
            readable.each do |sock|
              player = roster.find { |entry| entry[:socket] == sock }
              next unless player

              begin
                player[:buf] << sock.read_nonblock(4096)
                if player[:buf].bytesize > MAX_MSG_BYTES
                  broadcast(roster, { t: "match_end", reason: "disconnect", player_id: player[:id] }, except: player[:id])
                  close_players(roster)
                  return
                end
                if consume_wavesfight_messages(roster, session, player) == :rate_limit_exceeded
                  broadcast(roster, { t: "match_end", reason: "disconnect", player_id: player[:id] }, except: player[:id])
                  close_players(roster)
                  return
                end
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

          unless allow_message(player, msg[:t].to_s, session[:clock])
            player[:dropped_msgs] = (player[:dropped_msgs] || 0) + 1
            return :rate_limit_exceeded if player[:dropped_msgs] > MAX_DROPPED_MSGS

            next
          end

          case msg[:t]
          when "ping"
            send_json(player[:socket], { t: "pong", ts: msg[:ts] })
          when "state"
            next unless valid_position?(msg, session[:map])

            new_x = msg[:x].to_f
            new_y = msg[:y].to_f
            next unless position_delta_acceptable?(player[:x], player[:y], player[:last_state_at],
                                                  new_x, new_y, session[:clock])

            player[:x] = new_x
            player[:y] = new_y
            player[:angle] = msg[:a].to_f
            player[:last_state_at] = session[:clock]
            weapon = normalize_weapon(msg[:w], player)
            player[:weapon] = weapon if weapon
            if msg.key?(:am)
              ammo = validate_int(msg[:am], min: 0, max: 999)
              player[:ammo] = ammo if ammo
            end
            ff = validate_int(msg[:ff], min: 0, max: 10)
            player[:fire_flash] = ff || 0
          when "fire"
            player[:fire_flash] = 4
            process_wavesfight_fire(session, player)
          when "pickup"
            process_pickup(session, player, msg)
          end
        end
      end

      def process_pickup(session, player, msg)
        drop_id = msg[:id]
        return unless drop_id.is_a?(Numeric)

        drop = session[:drops].find { |d| d[:id] == drop_id }
        return unless drop

        dx = drop[:x] - player[:x]
        dy = drop[:y] - player[:y]
        return if (dx * dx + dy * dy) > Config::PICKUP_RADIUS**2
        return unless ALLOWED_MP_WEAPONS.include?(drop[:type].to_s)

        if player[:weapon] == drop[:type]
          weapon_klass = Weapon::Base.registry[drop[:type]]
          max = weapon_klass&.new&.max_ammo
          player[:ammo] = max ? [player[:ammo] + drop[:ammo], max].min : player[:ammo]
        else
          spawn_drop(session, player[:x], player[:y], player[:weapon], player[:ammo]) if player[:weapon]
          player[:weapon] = drop[:type]
          player[:ammo] = drop[:ammo]
          player[:obtained_weapons] << drop[:type]
        end
        session[:drops].delete(drop)
      end

      def update_wavesfight_session(roster, session, dt)
        roster.each do |player|
          player[:fire_flash] -= 1 if player[:fire_flash].to_i > 0
          regen_player(player, dt, session[:clock])
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
              apply_damage_to_player(target, dmg, session[:clock])
              send_json(target[:socket], { t: "hit", d: dmg, s: target[:shield], h: target[:health] })
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
        return if best.alive

        spawn_drop(session, best.x, best.y, best.drop_type, best.drop_ammo)
      end

      def spawn_drop(session, x, y, type, ammo)
        id = session[:next_drop_id]
        session[:next_drop_id] += 1
        session[:drops] << { id: id, x: x, y: y, type: type, ammo: ammo }
      end

      def enemy_damage(type)
        enemy_klass = Enemy::Base.registry[type]
        enemy_klass ? enemy_klass.allocate.send(:damage) : 10
      end

      def apply_damage_to_player(player, amount, clock)
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

      def regen_player(player, dt, now)
        return unless player[:alive]

        if player[:shield] < Config::SHIELD_MAX && (now - player[:last_damage]) >= Config::SHIELD_DELAY
          player[:shield] = [player[:shield] + Config::SHIELD_REGEN * dt, Config::SHIELD_MAX].min
        end
        return unless player[:shield] >= Config::SHIELD_MAX && player[:health] < Config::HEALTH_MAX

        player[:health] = [player[:health] + Config::SHIELD_REGEN * dt, Config::HEALTH_MAX].min
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
          drops: session[:drops].map { |drop| { id: drop[:id], x: drop[:x], y: drop[:y], type: drop[:type], am: drop[:ammo] } }
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
          player[:shield] = Config::SHIELD_MAX
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

      def load_cert
        cert_file = ENV["TERMFRONT_TLS_CERT_FILE"]
        key_file  = ENV["TERMFRONT_TLS_KEY_FILE"]

        if cert_file.nil? || cert_file.empty? || key_file.nil? || key_file.empty?
          raise "TLS not configured: set TERMFRONT_TLS_CERT_FILE and TERMFRONT_TLS_KEY_FILE to PEM paths " \
                "(use a fullchain certificate, e.g. issued by Let's Encrypt)."
        end
        unless File.exist?(cert_file) && File.exist?(key_file)
          raise "TLS cert or key file not found at the configured paths."
        end

        certs = OpenSSL::X509::Certificate.load(File.read(cert_file))
        certs = [certs] unless certs.is_a?(Array)
        cert = certs.first
        chain = certs.drop(1)
        key = OpenSSL::PKey::RSA.new(File.read(key_file))
        puts "Loaded TLS certificate."
        [cert, key, chain]
      end

      def wavesfight_mission_ids
        @wavesfight_mission_ids ||= Mission::Base.wavesfight.map { |klass| klass.new.id }.freeze
      end

      def pvp_map
        @pvp_map ||= Map.new(PVP_MAP)
      end

      def pvp_spawns
        @pvp_spawns ||= begin
          PVP_SPAWN_CANDIDATES.each do |spawn|
            x, y, = spawn
            raise "Invalid PvP spawn #{spawn.inspect}" if pvp_map.blocked?(x, y)
          end
          PVP_SPAWN_CANDIDATES
        end
      end
    end
  end
end
