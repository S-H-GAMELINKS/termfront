# frozen_string_literal: true

module Termfront
  module Network
    class Client
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

      def initialize(stdout)
        @stdout = stdout
        @conn = Connection.new
        @input = Input.new
        @renderer = Renderer.new(stdout)
        @audio = AudioManager.new
      end

      def run
        addr = prompt_address
        return unless addr

        host, port = addr.include?(":") ? addr.split(":", 2).then { |h, p| [h, p.to_i] } : [addr, Config::PVP_PORT]
        begin
          @conn.connect(host, port)
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

      def prompt_address
        input = "localhost:#{Config::PVP_PORT}"

        STDIN.raw do |stdin|
          loop do
            rows, cols = @stdout.winsize
            buf = TerminalOutput.begin_frame(home: true, clear: true)
            lines = Array.new(rows) { " " * cols }

            title = "PvP - Enter Server Address"
            tc = [(cols - title.size) / 2 + 1, 1].max
            lines[rows / 2 - 3] = TerminalOutput.fit_ansi("#{" " * (tc - 1)}\e[1;96m#{title}\e[0m", cols)

            prompt = "> #{input}_"
            pc = [(cols - prompt.size) / 2 + 1, 1].max
            lines[rows / 2 - 1] = TerminalOutput.fit_ansi("#{" " * (pc - 1)}\e[97m> #{input}\e[5m_\e[0m", cols)

            hint = "(Enter to connect, ESC to cancel)"
            hc = [(cols - hint.size) / 2 + 1, 1].max
            lines[rows / 2 + 1] = TerminalOutput.fit_ansi("#{" " * (hc - 1)}\e[90m#{hint}\e[0m", cols)

            lines.each_with_index do |line, index|
              buf << line
              buf << "\r\n" if index < rows - 1
            end
            buf << TerminalOutput.end_frame
            TerminalOutput.write_all(@stdout, buf)

            next unless IO.select([stdin], nil, nil, Config::FRAME_DT)

            begin
              data = stdin.read_nonblock(64)
              data.each_byte do |b|
                case b
                when 27 then return nil
                when 13, 10 then return input.empty? ? "localhost:#{Config::PVP_PORT}" : input
                when 127, 8 then input = input[0...-1] unless input.empty?
                when 32..126 then input << b.chr
                end
              end
            rescue IO::WaitReadable
              # ignore
            end
          end
        end
      end

      def wait_for_start
        STDIN.raw do |stdin|
          loop do
            rows, cols = @stdout.winsize
            buf = TerminalOutput.begin_frame(home: true, clear: true)
            lines = Array.new(rows) { " " * cols }
            msg = "Waiting for opponent..."
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

              load_pvp_match(msg[:map], msg[:spawn], msg[:opp_spawn])
              @pvp_id = msg[:id]
              return true
            end
          end
        end
      end

      def load_pvp_match(map_data, spawn, opp_spawn)
        @map = Map.new(map_data)
        weapons = [Weapon::Base.build(:ar, 60), Weapon::Base.build(:pistol)]
        @player = Player.new(x: spawn[0], y: spawn[1], angle: spawn[2], weapons: weapons)
        @player.drops = []

        @opponent = Opponent.new(x: opp_spawn[0], y: opp_spawn[1], angle: opp_spawn[2])
        @opp_prev = Opponent.new(x: opp_spawn[0], y: opp_spawn[1], angle: opp_spawn[2])
        @opp_render = Opponent.new(x: opp_spawn[0], y: opp_spawn[1], angle: opp_spawn[2])
        @opp_dead = false
        @opp_lerp_t = 1.0
        @projectiles = []
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
            return if @input.key?(:q) || @input.key?(:esc)

            handle_player_actions(keys)

            handle_messages
            update(dt)
            send_state
            interpolate_opponent(dt)
            render_pvp

            if @player.dead
              render_pvp_result("DEFEATED", "\e[1;91m")
              sleep 3
              return
            end

            if @opp_dead
              render_pvp_result("VICTORY", "\e[1;92m")
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

        if keys.include?(:e)
          @player.try_pickup
        end

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
            @opp_prev.x = @opp_render.x
            @opp_prev.y = @opp_render.y
            @opp_prev.angle = @opp_render.angle

            @opponent.x = msg[:x]
            @opponent.y = msg[:y]
            @opponent.angle = msg[:a]
            @opponent.shield = msg[:s]
            @opponent.health = msg[:h]
            @opponent.weapon = msg[:w]&.to_sym
            @opponent.ammo = msg[:am]
            @opponent.fire_flash = msg[:ff] || 0
            @opp_lerp_t = 0.0
          when "hit"
            @player.apply_damage(msg[:d] || Config::PVP_HIT_DMG)
            @audio.play_se(:damage)
          when "dead"
            @opp_dead = true
          end
        end
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

        @player.update_shield(dt, @stdout, audio: @audio)

        return unless @player.dead

        @conn.send_msg({ t: "dead" })
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

        ox = @opp_render.x - @player.x
        oy = @opp_render.y - @player.y
        dot = ox * dx + oy * dy
        return if dot < 0.1

        perp = (ox * (-dy) + oy * dx).abs
        return if perp > weapon.hit_width

        return unless @map.line_of_sight?(@player.x, @player.y, @opp_render.x, @opp_render.y)

        @conn.send_msg({ t: "hit", d: Config::PVP_HIT_DMG })
      end

      def interpolate_opponent(dt)
        @opp_lerp_t = [@opp_lerp_t + dt * 15.0, 1.0].min
        t = @opp_lerp_t
        @opp_render.x = @opp_prev.x + (@opponent.x - @opp_prev.x) * t
        @opp_render.y = @opp_prev.y + (@opponent.y - @opp_prev.y) * t

        da = @opponent.angle - @opp_prev.angle
        da -= 2 * Math::PI while da > Math::PI
        da += 2 * Math::PI while da < -Math::PI
        @opp_render.angle = @opp_prev.angle + da * t
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
        render_opponent_3d(buf, view_h, view_w, virt_h, dists)
        buf << "\e[#{3 + view_h};1H"
        render_pvp_radar(buf, cols, radar_h)
        render_crosshair(buf, view_h, view_w, cols)
        render_damage_flash(buf, view_h, view_w)

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

      def render_opponent_3d(buf, view_h, view_w, virt_h, dists)
        dx = Math.cos(@player.angle)
        dy = Math.sin(@player.angle)
        px = -dy * Math.tan(Config::FOV / 2.0)
        py =  dx * Math.tan(Config::FOV / 2.0)
        inv = 1.0 / (px * dy - py * dx)

        ex = @opp_render.x - @player.x
        ey = @opp_render.y - @player.y
        tx = inv * (dy * ex - dx * ey)
        tz = inv * (-py * ex + px * ey)
        return if tz < 0.2

        sx = ((view_w / 2.0) * (1 + tx / tz)).to_i
        sprite_h = (virt_h / tz).to_i
        draw_top = [(virt_h / 2 - sprite_h / 2), 0].max
        draw_bot = [(virt_h / 2 + sprite_h / 2), virt_h].min
        sprite_w = (sprite_h / 2.0).to_i
        start_x = [sx - sprite_w / 2, 0].max
        end_x   = [sx + sprite_w / 2, view_w - 1].min

        actual_h = draw_bot - draw_top
        actual_w = end_x - start_x + 1
        return if actual_h < 1 || actual_w < 1

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
              top_color = ny0 ? Sprite.player(nx, ny0) : nil
              bot_color = ny1 ? Sprite.player(nx, ny1) : nil
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
              buf << "\e[#{3 + r};#{c + 1}H"
              fc = "60;180;220"
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

        # Shield + HP bar above sprite
        bar_row = (draw_top / 2.0).ceil - 1
        return unless bar_row >= 0 && bar_row < view_h

        bar_w = [actual_w, 2].max
        bar_sx = [sx - bar_w / 2, 0].max
        bar_ex = [bar_sx + bar_w - 1, view_w - 1].min
        total = @opponent.shield + @opponent.health
        max_total = Config::SHIELD_MAX + Config::HEALTH_MAX
        hp_pct = total.to_f / max_total
        filled = (hp_pct * (bar_ex - bar_sx + 1)).ceil
        bar_sx.upto(bar_ex) do |c|
          next if c < 0 || c >= view_w
          next if dists[c] < tz

          ci = c - bar_sx
          color = ci < filled ? "0;200;200" : "200;0;0"
          buf << "\e[#{3 + bar_row};#{c + 1}H\e[38;2;#{color}m\xE2\x96\x88\e[0m"
        end
      end

      def render_pvp_hud(buf, cols)
        bar_w = [cols - 20, 10].max
        pct = @player.shield / Config::SHIELD_MAX.to_f
        filled = (pct * bar_w).to_i
        empty  = bar_w - filled
        color = if pct >= 0.5
                  "\e[96m"
                elsif pct >= 0.25
                  "\e[93m"
                else
                  "\e[91m"
                end
        pct_s = "#{(pct * 100).to_i}%"
        shield_str = "SHIELD #{color}#{"█" * filled}#{"░" * empty}\e[0m #{pct_s}"

        opp_total = @opponent.shield + @opponent.health
        opp_pct = opp_total.to_f / (Config::SHIELD_MAX + Config::HEALTH_MAX)
        opp_str = "  OPP:#{format("%.0f", opp_pct * 100)}%"
        ping_str = " #{@conn.rtt}ms"

        pad = [(cols - bar_w - 15) / 2, 0].max
        buf << TerminalOutput.fit_ansi("#{" " * pad}#{shield_str}\e[97m#{opp_str}\e[90m#{ping_str}\e[0m", cols) << "\r\n"

        weapon = @player.current_weapon
        wcolor = weapon.type_id.to_s.start_with?("shock") ? "\e[96m" : "\e[97m"

        if weapon.max_ammo
          ammo_bar_w = 12
          ammo_pct = weapon.ammo.to_f / weapon.max_ammo
          ammo_filled = (ammo_pct * ammo_bar_w).to_i
          ammo_empty  = ammo_bar_w - ammo_filled
          ammo_str = "#{wcolor}#{weapon.name}\e[0m [#{"█" * ammo_filled}#{"░" * ammo_empty}] #{weapon.ammo}/#{weapon.max_ammo}"
        else
          ammo_str = "#{wcolor}#{weapon.name}\e[0m [\xe2\x88\x9e]"
        end

        line = "#{ammo_str}  T:swap  Space:fire"
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

        cos_a = Math.cos(-@player.angle + Math::PI / 2)
        sin_a = Math.sin(-@player.angle + Math::PI / 2)
        opp_cell = nil

        ex = @opp_render.x - @player.x
        ey = @opp_render.y - @player.y
        dist = Math.sqrt(ex * ex + ey * ey)
        if dist <= Config::RADAR_RANGE
          rx = -(ex * cos_a - ey * sin_a)
          ry = -(ex * sin_a + ey * cos_a)
          osx = r + (rx / Config::RADAR_RANGE * r).round
          osy = r + (ry / Config::RADAR_RANGE * r).round
          if osx.between?(0, diam - 1) && osy.between?(0, diam - 1)
            d2 = (osx - r)**2 + (osy - r)**2
            opp_cell = [osy, osx] if d2 <= r * r
          end
        end

        info_lines = [
          "Opponent: #{format("%.0f",
                              (@opponent.shield + @opponent.health).to_f / (Config::SHIELD_MAX + Config::HEALTH_MAX) * 100)}%",
          "Heading: #{format("%.0f", (@player.angle % (Math::PI * 2)) * 180 / Math::PI)}\xC2\xB0",
          "Ping: #{@conn.rtt}ms"
        ]

        radar_h.times do |row|
          line = +""
          if row < diam
            line << "  "
            diam.times do |cx|
              line << if opp_cell && opp_cell == [row, cx]
                        "\e[96m*\e[0m"
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
