# frozen_string_literal: true

module Termfront
  module Network
    class Client
      TEAM_SIZES = [1, 2, 4].freeze
      ALLOWED_WEAPONS = %w[pistol ar].freeze

      def initialize(stdout)
        @stdout = stdout
        @conn = Connection.new
        @input = Input.new
        @renderer = Renderer.new(stdout)
        @audio = AudioManager.new
      end

      def run
        team_size = prompt_team_size
        return unless team_size

        host, port = Config::PVP_DEFAULT_ADDRESS.split(":", 2).then { |h, p| [h, p.to_i] }
        begin
          @conn.connect(host, port, ca_file: ENV["TERMFRONT_TLS_CA_FILE"])
          @conn.send_msg({ t: "queue", team_size: team_size })
        rescue StandardError => e
          show_error("Connection failed: #{e.message}")
          return
        end

        begin
          unless wait_for_start(team_size)
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

      def prompt_team_size
        selected = 0

        STDIN.raw do |stdin|
          loop do
            rows, cols = @stdout.winsize
            buf = TerminalOutput.begin_frame(home: true, clear: true)
            lines = Array.new(rows) { " " * cols }

            title = "PvP - Select Match Size"
            tc = [(cols - title.size) / 2 + 1, 1].max
            lines[rows / 2 - 4] = TerminalOutput.fit_ansi("#{" " * (tc - 1)}\e[1;96m#{title}\e[0m", cols)

            TEAM_SIZES.each_with_index do |team_size, idx|
              label = "#{team_size}v#{team_size}"
              text = idx == selected ? "\e[30;103m #{label} \e[0m" : "\e[97m #{label} \e[0m"
              c = [(cols - label.size - 2) / 2 + 1, 1].max
              lines[rows / 2 - 1 + idx] = TerminalOutput.fit_ansi("#{" " * (c - 1)}#{text}", cols)
            end

            hint = "(Up/Down, J/K, or 1/2/4 to change, Enter to queue, ESC to cancel)"
            hc = [(cols - hint.size) / 2 + 1, 1].max
            lines[rows / 2 + 4] = TerminalOutput.fit_ansi("#{" " * (hc - 1)}\e[90m#{hint}\e[0m", cols)

            lines.each_with_index do |line, index|
              buf << line
              buf << "\r\n" if index < rows - 1
            end
            buf << TerminalOutput.end_frame
            TerminalOutput.write_all(@stdout, buf)

            next unless IO.select([stdin], nil, nil, Config::FRAME_DT)

            begin
              data = stdin.read_nonblock(64)
              bytes = data.bytes
              idx = 0
              while idx < bytes.size
                b = bytes[idx]
                case b
                when 27
                  if bytes[idx + 1] == 91 && bytes[idx + 2] == 65
                    selected = (selected - 1) % TEAM_SIZES.size
                    idx += 3
                    next
                  elsif bytes[idx + 1] == 91 && bytes[idx + 2] == 66
                    selected = (selected + 1) % TEAM_SIZES.size
                    idx += 3
                    next
                  else
                    return nil
                  end
                when 13, 10 then return TEAM_SIZES[selected]
                when 65, 107 then selected = (selected - 1) % TEAM_SIZES.size
                when 66, 106 then selected = (selected + 1) % TEAM_SIZES.size
                when 49 then return 1
                when 50 then return 2
                when 52 then return 4
                end
                idx += 1
              end
            rescue IO::WaitReadable
            end
          end
        end
      end

      def wait_for_start(team_size)
        STDIN.raw do |stdin|
          loop do
            rows, cols = @stdout.winsize
            buf = TerminalOutput.begin_frame(home: true, clear: true)
            lines = Array.new(rows) { " " * cols }
            msg = "Waiting for #{team_size}v#{team_size} match..."
            mc = [(cols - msg.size) / 2 + 1, 1].max
            lines[rows / 2 - 1] = TerminalOutput.fit_ansi("#{" " * (mc - 1)}\e[1;93m#{msg}\e[0m", cols)
            hint = "(ESC to cancel)"
            hc = [(cols - hint.size) / 2 + 1, 1].max
            lines[rows / 2 + 1] = TerminalOutput.fit_ansi("#{" " * (hc - 1)}\e[90m#{hint}\e[0m", cols)
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
              next unless msg[:t] == "start"

              load_pvp_match(msg[:map], msg[:players], msg[:id], msg[:team], msg[:team_size])
              return true
            end
          end
        end
      end

      def load_pvp_match(map_data, players, player_id, team, team_size)
        @map = Map.new(map_data)
        weapons = [Weapon::Base.build(:ar, 60), Weapon::Base.build(:pistol)]
        self_info = players.find { |entry| entry[:id] == player_id }
        spawn = self_info[:spawn]

        @player = Player.new(x: spawn[0], y: spawn[1], angle: spawn[2], weapons: weapons)
        @player.drops = []
        @player_id = player_id
        @team = team
        @team_size = team_size
        @match_end = nil
        @sent_dead = false
        @projectiles = []

        @remotes = {}
        players.each do |entry|
          next if entry[:id] == player_id

          @remotes[entry[:id]] = build_remote_player(entry)
        end
      end

      def build_remote_player(entry)
        spawn = entry[:spawn]
        current = Opponent.new(x: spawn[0], y: spawn[1], angle: spawn[2])
        prev = current.dup_state
        render = current.dup_state

        {
          id: entry[:id],
          team: entry[:team],
          current: current,
          prev: prev,
          render: render,
          lerp_t: 1.0
        }
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
              update(dt)
              send_state
            end

            handle_messages
            interpolate_opponents(dt)
            render_pvp

            if victory?
              render_pvp_result("VICTORY", "\e[1;92m")
              sleep 3
              return
            end

            if defeated?
              render_pvp_result("DEFEATED", "\e[1;91m")
              sleep 3
              return
            end

            if @match_end
              text = @match_end[:reason] == "disconnect" ? "MATCH CANCELED" : "MATCH ENDED"
              render_pvp_result(text, "\e[1;93m")
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
        @player.try_pickup if keys.include?(:e)

        return unless keys.include?(:space)

        weapon = @player.current_weapon
        return unless weapon.can_fire?(@player.last_fire, @player.game_time)
        return unless weapon.infinite_ammo? || (weapon.ammo && weapon.ammo > 0)

        @player.fire_flash = 4
        weapon.consume_ammo!
        @player.last_fire = @player.game_time
        @audio.play_se(:shoot)
      end

      def handle_messages
        @conn.receive.each do |msg|
          case msg[:t]
          when "state"
            update_remote_state(msg)
          when "hit"
            @player.apply_damage(msg[:d] || Config::PVP_HIT_DMG)
            @audio.play_se(:damage)
            notify_death_if_needed
          when "dead"
            @remotes.delete(msg[:from])
          when "match_end"
            @match_end = msg
          end
        end
      end

      def update_remote_state(msg)
        remote = @remotes[msg[:from]]
        return unless remote

        remote[:prev].x = remote[:render].x
        remote[:prev].y = remote[:render].y
        remote[:prev].angle = remote[:render].angle

        remote[:current].x = msg[:x]
        remote[:current].y = msg[:y]
        remote[:current].angle = msg[:a]
        remote[:current].shield = msg[:s]
        remote[:current].health = msg[:h]
        weapon = safe_weapon(msg[:w])
        remote[:current].weapon = weapon if weapon
        remote[:current].ammo = msg[:am]
        spawn_remote_projectile_effect(msg) if (remote[:current].fire_flash || 0) <= 0 && (msg[:ff] || 0) > 0
        remote[:current].fire_flash = msg[:ff] || 0
        remote[:lerp_t] = 0.0
      end

      def update(dt)
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

        process_fire_pvp if @player.fire_flash == 4
        @player.fire_flash -= 1 if @player.fire_flash > 0
        update_projectile_effects(dt)

        @player.update_shield(dt, @stdout, audio: @audio)

        notify_death_if_needed
      end

      def send_state
        @conn.send_msg({
                         t: "state",
                         x: @player.x.round(3),
                         y: @player.y.round(3),
                         a: @player.angle.round(4),
                         s: @player.shield.round(1),
                         h: @player.health.round(1),
                         w: @player.current_weapon.type_id,
                         am: @player.current_weapon.ammo || -1,
                         ff: @player.fire_flash
                       })
      end

      def process_fire_pvp
        dx = Math.cos(@player.angle)
        dy = Math.sin(@player.angle)
        weapon = @player.current_weapon

        best_target = nil
        best_dot = Float::INFINITY

        enemy_players.each do |remote|
          ox = remote[:render].x - @player.x
          oy = remote[:render].y - @player.y
          dot = ox * dx + oy * dy
          next if dot < 0.1

          perp = (ox * (-dy) + oy * dx).abs
          next if perp > weapon.hit_width
          next unless @map.line_of_sight?(@player.x, @player.y, remote[:render].x, remote[:render].y)
          next unless dot < best_dot

          best_target = remote
          best_dot = dot
        end
        return unless best_target

        @conn.send_msg({ t: "hit", target: best_target[:id], d: Config::PVP_HIT_DMG })
      end

      def interpolate_opponents(dt)
        @remotes.each_value do |remote|
          remote[:lerp_t] = [remote[:lerp_t] + dt * 15.0, 1.0].min
          t = remote[:lerp_t]
          remote[:render].x = remote[:prev].x + (remote[:current].x - remote[:prev].x) * t
          remote[:render].y = remote[:prev].y + (remote[:current].y - remote[:prev].y) * t

          da = remote[:current].angle - remote[:prev].angle
          da -= 2 * Math::PI while da > Math::PI
          da += 2 * Math::PI while da < -Math::PI
          remote[:render].angle = remote[:prev].angle + da * t
        end
      end

      def render_pvp
        rows, cols = @stdout.winsize
        rows = [rows, 6].max
        cols = [cols, 20].max

        radar_h = Config::RADAR_RADIUS * 2 + 1
        view_h = [rows - 3 - radar_h, 4].max
        view_w = cols
        virt_h = view_h * 2

        dx = Math.cos(@player.angle)
        dy = Math.sin(@player.angle)
        plane_x = -dy * Math.tan(Config::FOV / 2.0)
        plane_y = dx * Math.tan(Config::FOV / 2.0)

        dists = Array.new(view_w)
        sides = Array.new(view_w)
        view_w.times do |c|
          cam = 2.0 * c / view_w - 1.0
          dists[c], sides[c] = @renderer.cast_ray(@map, @player.x, @player.y, dx + plane_x * cam, dy + plane_y * cam)
        end

        vmid = virt_h / 2.0
        wtop = Array.new(view_w)
        wbot = Array.new(view_w)
        wcol = Array.new(view_w)
        view_w.times do |c|
          d = dists[c]
          lh = d > 0.01 ? (virt_h / d).to_i : virt_h
          wtop[c] = [(vmid - lh / 2.0).to_i, 0].max
          wbot[c] = [(vmid + lh / 2.0).to_i, virt_h].min
          wcol[c] = Sprite.wall_brightness(d, sides[c])
        end

        buf = TerminalOutput.begin_frame(home: true)
        render_pvp_hud(buf, cols)
        render_view(buf, view_h, view_w, wtop, wbot, wcol)
        render_remote_players_3d(buf, view_h, view_w, virt_h, dists)
        render_pvp_projectiles(buf, view_h, view_w, virt_h, dists)
        buf << "\e[#{3 + view_h};1H"
        render_pvp_radar(buf, cols, radar_h)
        render_crosshair(buf, view_h, view_w, cols)
        render_damage_flash(buf, view_h, view_w)
        render_status_overlay(buf, view_h, cols)
        buf << TerminalOutput.end_frame
        TerminalOutput.write_all(@stdout, buf)
      end

      def render_view(buf, view_h, view_w, wtop, wbot, wcol)
        view_h.times do |r|
          vp0 = r * 2
          vp1 = r * 2 + 1
          pfg = -1
          pbg = -1

          view_w.times do |c|
            tc = if vp0 < wtop[c]
                   Config::CEIL_C
                 else
                   (vp0 < wbot[c] ? wcol[c] : Config::FLOOR_C)
                 end
            bc = if vp1 < wtop[c]
                   Config::CEIL_C
                 else
                   (vp1 < wbot[c] ? wcol[c] : Config::FLOOR_C)
                 end

            if tc == bc
              if bc != pbg
                buf << "\e[48;5;#{bc}m"
                pbg = bc
              end
              buf << " "
            else
              if tc != pfg && bc != pbg
                buf << "\e[38;5;#{tc};48;5;#{bc}m"
              elsif tc != pfg
                buf << "\e[38;5;#{tc}m"
              elsif bc != pbg
                buf << "\e[48;5;#{bc}m"
              end
              pfg = tc
              pbg = bc
              buf << "\xE2\x96\x80"
            end
          end
          buf << "\e[0m\r\n"
        end
      end

      def render_remote_players_3d(buf, view_h, view_w, virt_h, dists)
        sorted_remotes = @remotes.values.sort_by do |remote|
          -distance_sq(remote[:render].x, remote[:render].y, @player.x, @player.y)
        end

        sorted_remotes.each do |remote|
          render_remote_player_3d(buf, view_h, view_w, virt_h, dists, remote)
        end
      end

      def render_remote_player_3d(buf, view_h, view_w, virt_h, dists, remote)
        dx = Math.cos(@player.angle)
        dy = Math.sin(@player.angle)
        px = -dy * Math.tan(Config::FOV / 2.0)
        py = dx * Math.tan(Config::FOV / 2.0)
        inv = 1.0 / (px * dy - py * dx)

        ex = remote[:render].x - @player.x
        ey = remote[:render].y - @player.y
        tx = inv * (dy * ex - dx * ey)
        tz = inv * (-py * ex + px * ey)
        return if tz < 0.2

        sx = ((view_w / 2.0) * (1 + tx / tz)).to_i
        sprite_h = (virt_h / tz).to_i
        draw_top = [(virt_h / 2 - sprite_h / 2), 0].max
        draw_bot = [(virt_h / 2 + sprite_h / 2), virt_h].min
        sprite_w = (sprite_h / 2.0).to_i
        start_x = [sx - sprite_w / 2, 0].max
        end_x = [sx + sprite_w / 2, view_w - 1].min

        actual_h = draw_bot - draw_top
        actual_w = end_x - start_x + 1
        return if actual_h < 1 || actual_w < 1

        color_mode = remote[:team] == @team ? :ally : :enemy
        use_shape = actual_h >= 6

        start_x.upto(end_x) do |c|
          next if c < 0 || c >= view_w
          next if dists[c] < tz

          nx = (c - start_x).to_f / actual_w
          r_top = (draw_top / 2.0).ceil
          r_bot = (draw_bot / 2.0).floor

          r_top.upto(r_bot - 1) do |r|
            vp0 = r * 2
            vp1 = r * 2 + 1
            top_in = vp0 >= draw_top && vp0 < draw_bot
            bot_in = vp1 >= draw_top && vp1 < draw_bot
            next unless top_in || bot_in

            if use_shape
              ny0 = top_in ? (vp0 - draw_top).to_f / actual_h : nil
              ny1 = bot_in ? (vp1 - draw_top).to_f / actual_h : nil
              top_color = ny0 ? tint_player_color(Sprite.player(nx, ny0), color_mode) : nil
              bot_color = ny1 ? tint_player_color(Sprite.player(nx, ny1), color_mode) : nil
              next unless top_color || bot_color

              buf << "\e[#{3 + r};#{c + 1}H"
              buf << if top_color && bot_color
                       if top_color == bot_color
                         "\e[38;2;#{top_color}m\xE2\x96\x88\e[0m"
                       else
                         "\e[38;2;#{top_color};48;2;#{bot_color}m\xE2\x96\x80\e[0m"
                       end
                     elsif top_color
                       "\e[38;2;#{top_color}m\xE2\x96\x80\e[0m"
                     else
                       "\e[38;2;#{bot_color}m\xE2\x96\x84\e[0m"
                     end
            else
              fc = color_mode == :ally ? "70;210;255" : "255;110;80"
              buf << "\e[#{3 + r};#{c + 1}H"
              buf << if top_in && bot_in
                       "\e[38;2;#{fc}m\xE2\x96\x88\e[0m"
                     elsif top_in
                       "\e[38;2;#{fc}m\xE2\x96\x80\e[0m"
                     else
                       "\e[38;2;#{fc}m\xE2\x96\x84\e[0m"
                     end
            end
          end
        end

        bar_row = (draw_top / 2.0).ceil - 1
        return unless bar_row >= 0 && bar_row < view_h

        bar_w = [actual_w, 2].max
        bar_sx = [sx - bar_w / 2, 0].max
        bar_ex = [bar_sx + bar_w - 1, view_w - 1].min
        total = remote[:current].shield + remote[:current].health
        max_total = Config::SHIELD_MAX + Config::HEALTH_MAX
        hp_pct = total.to_f / max_total
        filled = (hp_pct * (bar_ex - bar_sx + 1)).ceil
        fill_color = color_mode == :ally ? "0;180;255" : "255;80;80"

        bar_sx.upto(bar_ex) do |c|
          next if c < 0 || c >= view_w
          next if dists[c] < tz

          ci = c - bar_sx
          color = ci < filled ? fill_color : "80;20;20"
          buf << "\e[#{3 + bar_row};#{c + 1}H\e[38;2;#{color}m\xE2\x96\x88\e[0m"
        end
      end

      def render_pvp_projectiles(buf, view_h, view_w, virt_h, dists)
        dx = Math.cos(@player.angle)
        dy = Math.sin(@player.angle)
        px = -dy * Math.tan(Config::FOV / 2.0)
        py = dx * Math.tan(Config::FOV / 2.0)
        inv = 1.0 / (px * dy - py * dx)

        sprites = []
        @projectiles.each do |projectile|
          ex = projectile[:x] - @player.x
          ey = projectile[:y] - @player.y
          tx = inv * (dy * ex - dx * ey)
          tz = inv * (-py * ex + px * ey)
          next if tz < 0.2

          sprites << [tz, tx, projectile]
        end
        sprites.sort_by! { |sprite| -sprite[0] }

        sprites.each do |tz, tx, projectile|
          sx = ((view_w / 2.0) * (1 + tx / tz)).to_i
          pw = (4.0 / tz).ceil.clamp(1, 5)
          ph = (virt_h / tz * 0.15).ceil.clamp(2, 6)
          vmid = virt_h / 2
          draw_top = [(vmid - ph / 2), 0].max
          draw_bot = [(vmid + ph / 2).clamp(draw_top + 2, virt_h), virt_h].min
          start_x = [sx - pw / 2, 0].max
          end_x = [sx + pw / 2, view_w - 1].min

          start_x.upto(end_x) do |c|
            next if c < 0 || c >= view_w
            next if dists[c] < tz

            r_top = (draw_top / 2.0).ceil
            r_bot = [(draw_bot / 2.0).floor, r_top + 1].max
            r_top.upto(r_bot - 1) do |r|
              next if r < 0 || r >= view_h

              vp0 = r * 2
              vp1 = r * 2 + 1
              top_in = vp0 >= draw_top && vp0 < draw_bot
              bot_in = vp1 >= draw_top && vp1 < draw_bot
              next unless top_in || bot_in

              proj_color = projectile[:color]
              buf << "\e[#{3 + r};#{c + 1}H"
              buf << if top_in && bot_in
                       "\e[38;2;#{proj_color}m\xE2\x96\x88\e[0m"
                     elsif top_in
                       "\e[38;2;#{proj_color}m\xE2\x96\x80\e[0m"
                     else
                       "\e[38;2;#{proj_color}m\xE2\x96\x84\e[0m"
                     end
            end
          end
        end
      end

      def tint_player_color(color, mode)
        return nil unless color
        return color if mode == :ally

        r, g, b = color.split(";").map(&:to_i)
        nr = [[r + 70, 255].min, 0].max
        ng = [[g - 50, 0].max, 0].max
        nb = [[b - 90, 0].max, 0].max
        "#{nr};#{ng};#{nb}"
      end

      def render_pvp_hud(buf, cols)
        bar_w = [cols - 30, 10].max
        pct = @player.shield / Config::SHIELD_MAX.to_f
        filled = (pct * bar_w).to_i
        empty = bar_w - filled
        color = if pct >= 0.5
                  "\e[96m"
                elsif pct >= 0.25
                  "\e[93m"
                else
                  "\e[91m"
                end
        pct_s = "#{(pct * 100).to_i}%"
        shield_str = "SHIELD #{color}#{"█" * filled}#{"░" * empty}\e[0m #{pct_s}"

        enemies_left = enemy_players.count
        allies_left = alive_allies_count
        match_str = "  #{allies_left}A/#{enemies_left}E  #{@team_size}v#{@team_size}"
        ping_str = " #{@conn.rtt}ms"

        pad = [(cols - bar_w - 20) / 2, 0].max
        buf << TerminalOutput.fit_ansi("#{" " * pad}#{shield_str}\e[97m#{match_str}\e[90m#{ping_str}\e[0m", cols) << "\r\n"

        weapon = @player.current_weapon
        wcolor = weapon.type_id.to_s.start_with?("shock") ? "\e[96m" : "\e[97m"

        ammo_str = if weapon.max_ammo
                     ammo_bar_w = 12
                     ammo_pct = weapon.ammo.to_f / weapon.max_ammo
                     ammo_filled = (ammo_pct * ammo_bar_w).to_i
                     ammo_empty = ammo_bar_w - ammo_filled
                     "#{wcolor}#{weapon.name}\e[0m [#{"█" * ammo_filled}#{"░" * ammo_empty}] #{weapon.ammo}/#{weapon.max_ammo}"
                   else
                     "#{wcolor}#{weapon.name}\e[0m [\xE2\x88\x9E]"
                   end

        status = @player.dead ? "  \e[91mELIMINATED\e[0m" : ""
        line = "#{ammo_str}  T:swap  Space:fire#{status}"
        buf << TerminalOutput.fit_ansi(line, cols) << "\r\n"
      end

      def render_pvp_radar(buf, cols, radar_h)
        buf << ("\xE2\x94\x80" * cols)[0, cols * 3] << "\r\n"

        r = Config::RADAR_RADIUS
        diam = r * 2 + 1
        grid = Array.new(diam) { Array.new(diam, " ") }
        diam.times do |ry|
          diam.times do |rx|
            ddx = rx - r
            ddy = ry - r
            d2 = ddx * ddx + ddy * ddy
            if d2 <= r * r
              grid[ry][rx] = "."
            elsif d2 <= (r + 1) * (r + 1)
              grid[ry][rx] = "#"
            end
          end
        end
        grid[r][r] = "^"

        markers = radar_markers(r, diam)
        info_lines = [
          "Allies: #{alive_allies_count}/#{@team_size}",
          "Enemies: #{enemy_players.count}/#{@team_size}",
          "Ping: #{@conn.rtt}ms"
        ]

        radar_h.times do |row|
          line = +""
          if row < diam
            line << "  "
            diam.times do |cx|
              marker = markers[[row, cx]]
              line << if marker == :ally
                        "\e[96m+\e[0m"
                      elsif marker == :enemy
                        "\e[91m*\e[0m"
                      elsif row == r && cx == r
                        "\e[92m^\e[0m"
                      elsif grid[row][cx] == "#"
                        "\e[90m#\e[0m"
                      else
                        grid[row][cx]
                      end
            end
            line << (row < info_lines.size ? "    #{info_lines[row]}" : "")
          end
          buf << TerminalOutput.fit_ansi(line, cols)
          buf << "\r\n" if row < radar_h - 1
        end
      end

      def radar_markers(radius, diam)
        cos_a = Math.cos(-@player.angle + Math::PI / 2)
        sin_a = Math.sin(-@player.angle + Math::PI / 2)
        markers = {}

        @remotes.each_value do |remote|
          ex = remote[:render].x - @player.x
          ey = remote[:render].y - @player.y
          dist = Math.sqrt(ex * ex + ey * ey)
          next if dist > Config::RADAR_RANGE

          rx = -(ex * cos_a - ey * sin_a)
          ry = -(ex * sin_a + ey * cos_a)
          osx = radius + (rx / Config::RADAR_RANGE * radius).round
          osy = radius + (ry / Config::RADAR_RANGE * radius).round
          next unless osx.between?(0, diam - 1) && osy.between?(0, diam - 1)

          d2 = (osx - radius)**2 + (osy - radius)**2
          next unless d2 <= radius * radius

          markers[[osy, osx]] = remote[:team] == @team ? :ally : :enemy
        end

        markers
      end

      def render_crosshair(buf, view_h, view_w, cols)
        cr = 3 + (view_h / 2)
        cc = view_w / 2 + 1
        buf << "\e[#{cr};#{cc}H\e[97m+\e[0m"

        return unless @player.fire_flash > 0

        hw = [@player.fire_flash * 4, view_w / 4].min
        fs = [cc - hw, 1].max
        fe = [cc + hw, cols].min
        buf << "\e[#{cr};#{fs}H\e[93m#{"*" * (fe - fs + 1)}\e[0m"
      end

      def render_damage_flash(buf, view_h, view_w)
        return unless @player.damage_flash > 0

        intensity = @player.damage_flash * 60
        flash_w = 2

        view_h.times do |r|
          buf << "\e[#{3 + r};1H\e[48;2;#{intensity};0;0m#{" " * flash_w}\e[0m"
          rc = [view_w - flash_w + 1, 1].max
          buf << "\e[#{3 + r};#{rc}H\e[48;2;#{intensity};0;0m#{" " * flash_w}\e[0m"
        end
      end

      def render_status_overlay(buf, view_h, cols)
        return unless @player.dead && !defeated? && !victory?

        text = "SPECTATING TEAM"
        c = [(cols - text.size) / 2 + 1, 1].max
        buf << "\e[#{2 + [view_h / 4, 1].max};#{c}H\e[1;93m#{text}\e[0m"
      end

      def render_pvp_result(text, color_code)
        rows, cols = @stdout.winsize
        buf = +"\e[H"
        rows.times { buf << "#{" " * cols}\r\n" }
        r = rows / 2
        c = [(cols - text.size) / 2 + 1, 1].max
        buf << "\e[#{r};#{c}H#{color_code}#{text}\e[0m"
        TerminalOutput.write_all(@stdout, buf)
      end

      def show_error(msg)
        rows, cols = @stdout.winsize
        buf = TerminalOutput.begin_frame(home: true, clear: true)
        mc = [(cols - msg.size) / 2, 1].max
        buf << "\e[#{rows / 2};#{mc}H\e[1;91m#{msg}\e[0m"
        hint = "(Press any key)"
        hc = [(cols - hint.size) / 2, 1].max
        buf << "\e[#{rows / 2 + 2};#{hc}H\e[90m#{hint}\e[0m"
        buf << TerminalOutput.end_frame
        TerminalOutput.write_all(@stdout, buf)
        STDIN.raw { |s| s.getc }
      end

      def spawn_remote_projectile_effect(msg)
        shock = msg[:w].to_s.start_with?("shock")
        color = shock ? "80;220;255" : "255;210;80"
        speed = shock ? 18.0 : 14.0
        angle = msg[:a]
        @projectiles << {
          x: msg[:x],
          y: msg[:y],
          vx: Math.cos(angle) * speed,
          vy: Math.sin(angle) * speed,
          ttl: 0.18,
          color: color
        }
      end

      def update_projectile_effects(dt)
        @projectiles.reject! do |projectile|
          projectile[:x] += projectile[:vx] * dt
          projectile[:y] += projectile[:vy] * dt
          projectile[:ttl] -= dt
          projectile[:ttl] <= 0 || @map.wall_at?(projectile[:x], projectile[:y])
        end
      end

      def notify_death_if_needed
        return unless @player.dead
        return if @sent_dead

        @conn.send_msg({ t: "dead" })
        @sent_dead = true
      end

      def enemy_players
        @remotes.values.select { |remote| remote[:team] != @team }
      end

      def alive_allies_count
        remote_allies = @remotes.values.count { |remote| remote[:team] == @team }
        remote_allies + (@player.dead ? 0 : 1)
      end

      def victory?
        enemy_players.empty?
      end

      def defeated?
        @player.dead && alive_allies_count.zero?
      end

      def distance_sq(x1, y1, x2, y2)
        (x1 - x2)**2 + (y1 - y2)**2
      end

      def clock
        Process.clock_gettime(Process::CLOCK_MONOTONIC)
      end

      def cap_frame(frame_start)
        spent = clock - frame_start
        remain = Config::FRAME_DT - spent
        sleep(remain) if remain > 0
      end

      def safe_weapon(value)
        return nil unless value.is_a?(String) || value.is_a?(Symbol)

        name = value.to_s
        return nil unless ALLOWED_WEAPONS.include?(name)

        name.to_sym
      end
    end
  end
end
