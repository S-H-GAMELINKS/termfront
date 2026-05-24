# frozen_string_literal: true

module Termfront
  module Network
    class WavesfightClient
      def initialize(stdout)
        @stdout = stdout
        @conn = Connection.new
        @input = Input.new
        @renderer = Renderer.new(stdout)
        @audio = AudioManager.new
      end

      def run(mission_id:, difficulty:)
        @queue_mission_id = mission_id
        @queue_difficulty = difficulty

        host, port = Config::PVP_DEFAULT_ADDRESS.split(":", 2).then { |h, p| [h, p.to_i] }
        begin
          @conn.connect(host, port, ca_file: ENV["TERMFRONT_TLS_CA_FILE"])
          @conn.send_msg({ t: "queue", mode: "wavesfight", mission_id: mission_id, difficulty: difficulty })
        rescue StandardError => e
          show_error("Connection failed: #{e.message}")
          return
        end

        begin
          unless wait_for_start
            @conn.close
            return
          end
          run_game_loop
        rescue StandardError => e
          show_error("Error: #{e.message}")
        ensure
          @audio.close
          @conn.close
        end
      end

      private

      def wait_for_start
        STDIN.raw do |stdin|
          loop do
            rows, cols = @stdout.winsize
            buf = TerminalOutput.begin_frame(home: true, clear: true)
            lines = Array.new(rows) { " " * cols }
            msg = "Waiting for co-op partner..."
            mc = [(cols - msg.size) / 2 + 1, 1].max
            lines[rows / 2 - 2] = TerminalOutput.fit_ansi("#{" " * (mc - 1)}\e[1;93m#{msg}\e[0m", cols)
            detail = "#{queued_mission_name}  |  #{queued_difficulty_name}"
            dc = [(cols - detail.size) / 2 + 1, 1].max
            lines[rows / 2] = TerminalOutput.fit_ansi("#{" " * (dc - 1)}\e[38;2;170;170;190m#{detail}\e[0m", cols)
            hint = "(ESC to cancel)"
            hc = [(cols - hint.size) / 2 + 1, 1].max
            lines[rows / 2 + 2] = TerminalOutput.fit_ansi("#{" " * (hc - 1)}\e[90m#{hint}\e[0m", cols)

            lines.each_with_index do |line, index|
              buf << line
              buf << "\r\n" if index < rows - 1
            end
            buf << TerminalOutput.end_frame
            TerminalOutput.write_all(@stdout, buf)

            if IO.select([stdin], nil, nil, 0)
              begin
                ch = stdin.read_nonblock(64)
                return false if ch.bytes.include?(27)
              rescue IO::WaitReadable
              end
            end

            next unless IO.select([@conn.socket], nil, nil, 0.1)

            @conn.receive.each do |msg|
              next unless msg[:t] == "wavesfight_start"

              load_match(msg)
              return true
            end
          end
        end
      end

      def load_match(msg)
        @map = Map.new(msg[:map])
        @mission_name = msg[:mission]
        @player_id = msg[:id]
        @wave = 1
        @difficulty = 1
        self_info = msg[:players].find { |entry| entry[:id] == @player_id }
        weapons = [Weapon::Base.build(:ar, 60), Weapon::Base.build(:pistol)]
        @player = Player.new(x: self_info[:spawn][0], y: self_info[:spawn][1], angle: self_info[:spawn][2], weapons: weapons)
        @player.drops = []
        @remote_players = {}
        msg[:players].each do |entry|
          next if entry[:id] == @player_id

          @remote_players[entry[:id]] = Opponent.new(x: entry[:spawn][0], y: entry[:spawn][1], angle: entry[:spawn][2])
        end
        @enemies = []
        @projectiles = []
        @match_end = nil
        @regen_active = false
      end

      def run_game_loop
        STDIN.raw do |stdin|
          last_time = clock
          last_ping = clock

          loop do
            now = clock
            dt = now - last_time
            last_time = now

            keys = @input.process(stdin, player: @player)
            return if @input.key?(:esc)

            unless @player.dead
              handle_player_actions(keys)
              update_local(dt)
              send_state
            end

            handle_messages
            render_world

            if @match_end
              text = @match_end[:reason] == "defeat" ? "TEAM DOWN AT WAVE #{@match_end[:wave]}" : "MATCH CANCELED"
              render_result(text, @match_end[:reason] == "defeat" ? "\e[1;91m" : "\e[1;93m")
              sleep 3
              return
            end

            if now - last_ping > 2.0
              @conn.ping(now)
              last_ping = now
            end

            cap_frame(now)
          end
        end
      end

      def handle_player_actions(keys)
        @player.swap_weapon if keys.include?(:t)

        return unless keys.include?(:space)

        weapon = @player.current_weapon
        return unless weapon.can_fire?(@player.last_fire, @player.game_time)
        return unless weapon.infinite_ammo? || (weapon.ammo && weapon.ammo > 0)

        @player.fire_flash = 4
        weapon.consume_ammo!
        @player.last_fire = @player.game_time
        @audio.play_se(:shoot)
        @conn.send_msg({ t: "fire" })
      end

      def update_local(dt)
        @player.game_time += dt

        @player.angle -= Config::ROT_SPEED * dt if @input.key?(:left)
        @player.angle += Config::ROT_SPEED * dt if @input.key?(:right)

        dx = Math.cos(@player.angle)
        dy = Math.sin(@player.angle)
        sx = -dy
        sy = dx
        mvx = 0.0
        mvy = 0.0
        if @input.key?(:w)
          mvx += dx * Config::MOVE_SPEED * dt
          mvy += dy * Config::MOVE_SPEED * dt
        end
        if @input.key?(:s)
          mvx -= dx * Config::MOVE_SPEED * dt
          mvy -= dy * Config::MOVE_SPEED * dt
        end
        if @input.key?(:a)
          mvx -= sx * Config::MOVE_SPEED * dt
          mvy -= sy * Config::MOVE_SPEED * dt
        end
        if @input.key?(:d)
          mvx += sx * Config::MOVE_SPEED * dt
          mvy += sy * Config::MOVE_SPEED * dt
        end

        nx = @player.x + mvx
        @player.x = nx unless @map.blocked?(nx, @player.y)
        ny = @player.y + mvy
        @player.y = ny unless @map.blocked?(@player.x, ny)

        @player.fire_flash -= 1 if @player.fire_flash > 0
      end

      def send_state
        @conn.send_msg({
                         t: "state",
                         x: @player.x.round(3),
                         y: @player.y.round(3),
                         a: @player.angle.round(4),
                         w: @player.current_weapon.type_id,
                         am: @player.current_weapon.ammo || -1,
                         ff: @player.fire_flash
                       })
      end

      def handle_messages
        @conn.receive.each do |msg|
          case msg[:t]
          when "world"
            apply_world(msg)
          when "hit"
            @player.apply_damage(msg[:d] || Config::PVP_HIT_DMG)
            @audio.play_se(:damage)
          when "wave_start"
            @wave = msg[:wave]
            @difficulty = msg[:difficulty]
          when "match_end"
            @match_end = msg
          end
        end
      end

      def apply_world(msg)
        @wave = msg[:wave]
        @difficulty = msg[:difficulty]

        msg[:players].each do |entry|
          if entry[:id] == @player_id
            prev_shield = @player.shield
            @player.shield = entry[:s]
            @player.health = entry[:h]
            @player.dead = !entry[:alive]
            update_regen_audio(prev_shield)
          else
            remote = @remote_players[entry[:id]]
            next unless remote

            remote.x = entry[:x]
            remote.y = entry[:y]
            remote.angle = entry[:a]
            remote.shield = entry[:s]
            remote.health = entry[:h]
            remote.weapon = entry[:w]&.to_sym
            remote.ammo = entry[:am]
            remote.fire_flash = entry[:ff] || 0
          end
        end

        @enemies = msg[:enemies].filter_map do |enemy|
          next unless enemy[:alive]

          RemoteEnemy.new(
            id: enemy[:id],
            x: enemy[:x],
            y: enemy[:y],
            sprite_id: enemy[:type].to_sym,
            hp: enemy[:hp],
            max_hp: enemy[:max_hp],
            alive: true
          )
        end

        @projectiles = msg[:projectiles].map do |projectile|
          Projectile.new(x: projectile[:x], y: projectile[:y], vx: 0.0, vy: 0.0, type: projectile[:type].to_sym)
        end
      end

      def update_regen_audio(prev_shield)
        regen_now = !@player.dead && @player.shield > prev_shield && @player.shield < Config::SHIELD_MAX
        if regen_now
          unless @regen_active
            @audio.play_loop_se(:shield_regen)
            @regen_active = true
          end
        elsif @regen_active
          @audio.stop_loop_se(:shield_regen)
          @regen_active = false
        end
      end

      def render_world
        allies = @remote_players.values.select { |remote| remote.health.positive? }
        status = "  WAVE #{@wave}  #{Enemy::Base::DIFFICULTIES[@difficulty][:name]}  CO-OP"
        @renderer.render(
          player: @player,
          map: @map,
          enemies: @enemies,
          projectiles: @projectiles,
          drops: [],
          terminals: [],
          status_line: status,
          allies: allies
        )
      end

      def render_result(text, color)
        rows, cols = @stdout.winsize
        @renderer.render_centered_message(rows, cols, text, color)
      end

      def show_error(msg)
        rows, cols = @stdout.winsize
        @renderer.render_centered_message(rows, cols, msg, "\e[1;91m")
        STDIN.raw { |stdin| stdin.getc }
      end

      def queued_mission_name
        mission = Mission::Base.wavesfight.find { |klass| klass.new.id == @queue_mission_id }
        mission ? mission.new.name : @queue_mission_id.to_s
      end

      def queued_difficulty_name
        Enemy::Base::DIFFICULTIES[@queue_difficulty][:name]
      end

      def clock
        Process.clock_gettime(Process::CLOCK_MONOTONIC)
      end

      def cap_frame(frame_start)
        spent = clock - frame_start
        remain = Config::FRAME_DT - spent
        sleep(remain) if remain > 0
      end
    end
  end
end
