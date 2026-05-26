# frozen_string_literal: true

module Termfront
  class Renderer
    RADAR_CRAWLER  = "\e[91m*\e[0m"
    RADAR_EXECUTOR = "\e[95m*\e[0m"
    RADAR_ALLY     = "\e[96m+\e[0m"
    RADAR_TERMINAL = "\e[96mT\e[0m"
    RADAR_PLAYER   = "\e[92m^\e[0m"
    RADAR_WALL     = "\e[90m#\e[0m"

    FG_256 = Array.new(256) { |i| "\e[38;5;#{i}m".freeze }.freeze
    BG_256 = Array.new(256) { |i| "\e[48;5;#{i}m".freeze }.freeze

    def initialize(stdout)
      @stdout = stdout
      @buf_view_w = 0
      @buf_virt_h = 0
      @radar_grid_template = build_radar_grid_template
      @hrule_cache = Hash.new { |h, c| h[c] = ("\xE2\x94\x80" * c)[0, c * 3].freeze }
      @radar_drop_glyphs = {}
      @radar_enemy_cells = {}
      @radar_drop_cells = {}
      @radar_terminal_cells = {}
      @radar_ally_cells = {}
      @fg_truecolor_cache = {}
      @bg_truecolor_cache = {}
      @enemy_sprites = []
      @proj_sprites = []
      @drop_sprites = []
      @ally_sprites = []
      @radar_line_buf = +""
      @size_cache = nil
      @size_cache_at = -Float::INFINITY
      @cached_hud_shield_key = nil
      @cached_hud_shield_line = nil
      @cached_hud_ammo_key = nil
      @cached_hud_ammo_line = nil
    end

    def invalidate_size_cache!
      @size_cache = nil
    end

    def render(player:, map:, enemies:, projectiles:, drops:, terminals: [], status_line: nil, allies: [])
      rows, cols = current_size
      rows = [rows, 6].max
      cols = [cols, 20].max

      radar_h = Config::RADAR_RADIUS * 2 + 1
      view_h = [rows - 3 - radar_h, 4].max
      view_w = cols
      virt_h = view_h * 2

      prepare_frame_buffers(view_w, virt_h)

      dx = Math.cos(player.angle)
      dy = Math.sin(player.angle)
      plane_x = -dy * Math.tan(Config::FOV / 2.0)
      plane_y = dx * Math.tan(Config::FOV / 2.0)

      view_w.times do |c|
        cam = 2.0 * c / view_w - 1.0
        @dists[c], @sides[c] = cast_ray(map, player.x, player.y, dx + plane_x * cam, dy + plane_y * cam)
      end

      vmid = virt_h / 2.0
      view_w.times do |c|
        d = @dists[c]
        lh = d > 0.01 ? (virt_h / d).to_i : virt_h
        @wtop[c] = [(vmid - lh / 2.0).to_i, 0].max
        @wbot[c] = [(vmid + lh / 2.0).to_i, virt_h].min
        @wcol[c] = Sprite.wall_brightness(d, @sides[c])
      end
      build_view_pixels(virt_h, view_w, @wtop, @wbot, @wcol)
      overlay_enemies_3d(@pixels, view_h, view_w, @dists, player, enemies, projectiles, drops)
      overlay_allies_3d(@pixels, view_h, view_w, @dists, player, allies)
      overlay_damage_flash(@pixels, view_h, view_w, player)

      buf = TerminalOutput.begin_frame(home: true)

      render_hud(buf, cols, player, drops, terminals, status_line)
      render_view(buf, view_h, view_w, @pixels)
      buf << "\e[#{3 + view_h};1H"
      render_radar(buf, cols, radar_h, player, enemies, drops, terminals, allies)
      render_crosshair(buf, view_h, view_w, cols, player)

      buf << TerminalOutput.end_frame
      TerminalOutput.write_all(@stdout, buf)
    end

    def render_game_over(rows, cols)
      render_centered_message(rows, cols, "GAME OVER", "\e[1;91m")
    end

    def render_mission_complete(rows, cols)
      render_centered_message(rows, cols, "MISSION COMPLETE", "\e[1;92m")
    end

    def render_blank(rows, cols)
      buf = TerminalOutput.begin_frame(home: true)
      rows.times do |row|
        buf << "\e[#{row + 1};1H"
        buf << (" " * cols)
      end
      buf << TerminalOutput.end_frame
      TerminalOutput.write_all(@stdout, buf)
    end

    def render_centered_message(rows, cols, msg, color)
      buf = TerminalOutput.begin_frame(home: true, clear: true)
      r = rows / 2
      c = [(cols - msg.size) / 2 + 1, 1].max
      buf << "\e[#{r};#{c}H#{color}#{msg}\e[0m"
      buf << TerminalOutput.end_frame
      TerminalOutput.write_all(@stdout, buf)
    end

    def cast_ray(map, ox, oy, rdx, rdy)
      mx = ox.floor
      my = oy.floor

      ddx = rdx == 0 ? 1e30 : (1.0 / rdx).abs
      ddy = rdy == 0 ? 1e30 : (1.0 / rdy).abs

      if rdx < 0
        step_x = -1
        sd_x = (ox - mx) * ddx
      else
        step_x = 1
        sd_x = (mx + 1.0 - ox) * ddx
      end
      if rdy < 0
        step_y = -1
        sd_y = (oy - my) * ddy
      else
        step_y = 1
        sd_y = (my + 1.0 - oy) * ddy
      end

      side = 0
      64.times do
        if sd_x < sd_y
          sd_x += ddx
          mx += step_x
          side = 0
        else
          sd_y += ddy
          my += step_y
          side = 1
        end
        return [1e30, 0] if my < 0 || my >= map.height || mx < 0 || mx >= map.width

        next unless map.grid[my][mx] == "#"

        d = if side == 0
              (mx - ox + (1 - step_x) / 2.0) / rdx
            else
              (my - oy + (1 - step_y) / 2.0) / rdy
            end
        return [d.abs, side]
      end
      [1e30, 0]
    end

    private

    def current_size
      now = Process.clock_gettime(Process::CLOCK_MONOTONIC)
      if @size_cache.nil? || now - @size_cache_at >= 0.25
        @size_cache = @stdout.winsize
        @size_cache_at = now
      end
      @size_cache
    end

    def build_radar_grid_template
      r = Config::RADAR_RADIUS
      diam = r * 2 + 1
      Array.new(diam) do |ry|
        Array.new(diam) do |rx|
          if ry == r && rx == r
            "^"
          else
            dx = rx - r
            dy = ry - r
            d2 = dx * dx + dy * dy
            if d2 <= r * r
              "."
            elsif d2 <= (r + 1) * (r + 1)
              "#"
            else
              " "
            end
          end
        end.freeze
      end.freeze
    end

    def radar_drop_glyph(drop)
      @radar_drop_glyphs[drop.type] ||= begin
        dc = drop.type.to_s.start_with?("shock") ? "\e[96m" : "\e[93m"
        dl = Weapon::Base.registry[drop.type].new.name[0]
        "#{dc}#{dl}\e[0m".freeze
      end
    end

    def prepare_frame_buffers(view_w, virt_h)
      if @buf_view_w != view_w || @buf_virt_h != virt_h
        @buf_view_w = view_w
        @buf_virt_h = virt_h
        @dists = Array.new(view_w)
        @sides = Array.new(view_w)
        @wtop  = Array.new(view_w)
        @wbot  = Array.new(view_w)
        @wcol  = Array.new(view_w)
        @pixels = Array.new(virt_h) { Array.new(view_w) }
      end
    end

    def render_hud(buf, cols, player, drops, terminals, status_line)
      buf << hud_shield_line(cols, player, status_line) << "\r\n"
      buf << hud_ammo_line(cols, player, drops, terminals) << "\r\n"
    end

    def hud_shield_line(cols, player, status_line)
      key = [player.shield.to_i, status_line, cols]
      return @cached_hud_shield_line if @cached_hud_shield_key == key

      bar_w = [cols - 20, 10].max
      pct = player.shield / Config::SHIELD_MAX.to_f
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
      shield_str = "#{shield_str}\e[90m#{status_line}\e[0m" if status_line
      pad = [(cols - bar_w - 15) / 2, 0].max
      line = TerminalOutput.fit_ansi("#{" " * pad}#{shield_str}", cols)

      @cached_hud_shield_key = key
      @cached_hud_shield_line = line
      line
    end

    def hud_ammo_line(cols, player, drops, terminals)
      weapon = player.current_weapon
      can_pickup = drops.any? { |d| d.in_range?(player.x, player.y) }
      can_use_terminal = terminals.any? do |terminal|
        (terminal[:x] - player.x)**2 + (terminal[:y] - player.y)**2 < Config::TERMINAL_USE_RADIUS**2
      end
      key = [weapon.type_id, weapon.ammo, can_pickup, can_use_terminal, cols]
      return @cached_hud_ammo_line if @cached_hud_ammo_key == key

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

      interact_str = if can_use_terminal
                       "\e[1;96m[E]Use Terminal\e[0m"
                     elsif can_pickup
                       "\e[1;93m[E]Pickup\e[0m"
                     else
                       "E:interact"
                     end

      line = TerminalOutput.fit_ansi("#{ammo_str}  T:swap  #{interact_str}  Space:fire", cols)

      @cached_hud_ammo_key = key
      @cached_hud_ammo_line = line
      line
    end

    def build_view_pixels(virt_h, view_w, wtop, wbot, wcol)
      ceil_c = Config::CEIL_C
      floor_c = Config::FLOOR_C
      pixels = @pixels

      min_wt = wtop.min
      max_wb = wbot.max
      upper_done = min_wt < virt_h ? min_wt : virt_h
      lower_start = max_wb > upper_done ? max_wb : upper_done
      lower_start = virt_h if lower_start > virt_h

      vr = 0
      while vr < upper_done
        pixels[vr].fill(ceil_c, 0, view_w)
        vr += 1
      end

      vr_bot = virt_h - 1
      while vr_bot >= lower_start
        pixels[vr_bot].fill(floor_c, 0, view_w)
        vr_bot -= 1
      end
      middle_end = vr_bot + 1

      c = 0
      while c < view_w
        wt = wtop[c]
        wb = wbot[c]
        wc = wcol[c]

        vr = upper_done
        while vr < wt && vr < middle_end
          pixels[vr][c] = ceil_c
          vr += 1
        end
        while vr < wb && vr < middle_end
          pixels[vr][c] = wc
          vr += 1
        end
        while vr < middle_end
          pixels[vr][c] = floor_c
          vr += 1
        end

        c += 1
      end
    end

    def render_view(buf, view_h, view_w, pixels)
      fg_256 = FG_256
      bg_256 = BG_256
      fg_cache = @fg_truecolor_cache
      bg_cache = @bg_truecolor_cache

      view_h.times do |r|
        vp0 = r * 2
        vp1 = r * 2 + 1
        pfg = nil
        pbg = nil
        top_row = pixels[vp0]
        bot_row = pixels[vp1]

        view_w.times do |c|
          tc = top_row[c]
          bc = bot_row[c]

          if tc == bc
            if tc.is_a?(Integer)
              if tc != pbg
                buf << bg_256[tc]
                pbg = tc
                pfg = nil
              end
              buf << " "
            else
              if tc != pfg || pbg
                buf << (fg_cache[tc] ||= "\e[38;2;#{tc}m".freeze)
                pfg = tc
                pbg = nil
              end
              buf << "\xE2\x96\x88"
            end
          else
            if tc != pfg || bc != pbg
              fg = tc.is_a?(Integer) ? fg_256[tc] : (fg_cache[tc] ||= "\e[38;2;#{tc}m".freeze)
              bg = bc.is_a?(Integer) ? bg_256[bc] : (bg_cache[bc] ||= "\e[48;2;#{bc}m".freeze)
              buf << fg << bg
              pfg = tc
              pbg = bc
            end
            buf << "\xE2\x96\x80"
          end
        end
        buf << "\e[0m\r\n"
      end
    end

    def render_radar(buf, cols, radar_h, player, enemies, drops, terminals, allies = [])
      buf << @hrule_cache[cols] << "\r\n"

      r = Config::RADAR_RADIUS
      diam = r * 2 + 1
      range = Config::RADAR_RANGE
      range_sq = Config::RADAR_RANGE_SQ
      r_sq = r * r
      grid = @radar_grid_template

      cos_a = Math.cos(-player.angle + Math::PI / 2)
      sin_a = Math.sin(-player.angle + Math::PI / 2)
      px = player.x
      py = player.y

      enemy_cells = @radar_enemy_cells
      drop_cells = @radar_drop_cells
      terminal_cells = @radar_terminal_cells
      ally_cells = @radar_ally_cells
      enemy_cells.clear
      drop_cells.clear
      terminal_cells.clear
      ally_cells.clear

      enemies.each do |e|
        next unless e.alive

        ex = e.x - px
        ey = e.y - py
        next if ex * ex + ey * ey > range_sq

        rx = -(ex * cos_a - ey * sin_a)
        ry = -(ex * sin_a + ey * cos_a)
        sx = r + (rx / range * r).round
        sy = r + (ry / range * r).round
        next if sx < 0 || sx >= diam || sy < 0 || sy >= diam

        dxr = sx - r
        dyr = sy - r
        next if dxr * dxr + dyr * dyr > r_sq

        enemy_cells[sy * diam + sx] = e.sprite_id
      end

      drops.each do |d|
        ex = d.x - px
        ey = d.y - py
        next if ex * ex + ey * ey > range_sq

        rx = -(ex * cos_a - ey * sin_a)
        ry = -(ex * sin_a + ey * cos_a)
        sx = r + (rx / range * r).round
        sy = r + (ry / range * r).round
        next if sx < 0 || sx >= diam || sy < 0 || sy >= diam

        dxr = sx - r
        dyr = sy - r
        next if dxr * dxr + dyr * dyr > r_sq

        drop_cells[sy * diam + sx] = d
      end

      terminals.each do |terminal|
        ex = terminal[:x] - px
        ey = terminal[:y] - py
        next if ex * ex + ey * ey > range_sq

        rx = -(ex * cos_a - ey * sin_a)
        ry = -(ex * sin_a + ey * cos_a)
        sx = r + (rx / range * r).round
        sy = r + (ry / range * r).round
        next if sx < 0 || sx >= diam || sy < 0 || sy >= diam

        dxr = sx - r
        dyr = sy - r
        next if dxr * dxr + dyr * dyr > r_sq

        terminal_cells[sy * diam + sx] = terminal
      end

      allies.each do |ally|
        ex = ally.x - px
        ey = ally.y - py
        next if ex * ex + ey * ey > range_sq

        rx = -(ex * cos_a - ey * sin_a)
        ry = -(ex * sin_a + ey * cos_a)
        sx = r + (rx / range * r).round
        sy = r + (ry / range * r).round
        next if sx < 0 || sx >= diam || sy < 0 || sy >= diam

        dxr = sx - r
        dyr = sy - r
        next if dxr * dxr + dyr * dyr > r_sq

        ally_cells[sy * diam + sx] = true
      end

      alive_count = enemies.count(&:alive)
      total_count = enemies.size
      info_lines = [
        "Enemies: #{alive_count}/#{total_count}",
        "Heading: #{format("%.0f", (player.angle % (Math::PI * 2)) * 180 / Math::PI)}\xC2\xB0",
        "Pos: (#{"%.1f" % px}, #{"%.1f" % py})  T:terminal"
      ]

      row = 0
      while row < radar_h
        line = @radar_line_buf.clear
        if row < diam
          line << "  "
          cx = 0
          base = row * diam
          while cx < diam
            key = base + cx
            if (etype = enemy_cells[key])
              line << (etype == :executor ? RADAR_EXECUTOR : RADAR_CRAWLER)
            elsif ally_cells[key]
              line << RADAR_ALLY
            elsif (drop = drop_cells[key])
              line << radar_drop_glyph(drop)
            elsif terminal_cells[key]
              line << RADAR_TERMINAL
            elsif row == r && cx == r
              line << RADAR_PLAYER
            elsif grid[row][cx] == "#"
              line << RADAR_WALL
            else
              line << grid[row][cx]
            end
            cx += 1
          end
          line << (row < info_lines.size ? "    #{info_lines[row]}" : "")
        end
        buf << TerminalOutput.fit_ansi(line, cols)
        buf << "\r\n" if row < radar_h - 1
        row += 1
      end
    end

    def overlay_enemies_3d(pixels, view_h, view_w, dists, player, enemies, projectiles, drops)
      dx = Math.cos(player.angle)
      dy = Math.sin(player.angle)
      tan_half_fov = Math.tan(Config::FOV / 2.0)
      px = -dy * tan_half_fov
      py = dx * tan_half_fov
      virt_h = view_h * 2
      half_virt_h = virt_h / 2
      half_view_w = view_w / 2.0
      view_w_last = view_w - 1
      inv = 1.0 / (px * dy - py * dx)
      player_x = player.x
      player_y = player.y

      @enemy_sprites.clear
      enemies.each do |e|
        next unless e.alive

        ex = e.x - player_x
        ey = e.y - player_y
        tx = inv * (dy * ex - dx * ey)
        tz = inv * (-py * ex + px * ey)
        next if tz < 0.2

        @enemy_sprites << [tz, tx, e]
      end

      @proj_sprites.clear
      projectiles.each do |p|
        ex = p.x - player_x
        ey = p.y - player_y
        tx = inv * (dy * ex - dx * ey)
        tz = inv * (-py * ex + px * ey)
        next if tz < 0.2

        @proj_sprites << [tz, tx, p]
      end

      @enemy_sprites.sort! { |a, b| b[0] <=> a[0] }

      @enemy_sprites.each do |tz, tx, e|
        sx = (half_view_w * (1 + tx / tz)).to_i
        sprite_h = (virt_h / tz).to_i
        draw_top = half_virt_h - sprite_h / 2
        draw_top = 0 if draw_top < 0
        draw_bot = half_virt_h + sprite_h / 2
        draw_bot = virt_h if draw_bot > virt_h
        sprite_w = sprite_h / 2
        start_x = sx - sprite_w / 2
        start_x = 0 if start_x < 0
        end_x = sx + sprite_w / 2
        end_x = view_w_last if end_x > view_w_last

        actual_h = draw_bot - draw_top
        actual_w = end_x - start_x + 1
        next if actual_h < 1 || actual_w < 1

        sprite_id = e.sprite_id
        fallback_color = sprite_id == :executor ? "100;60;200" : "220;140;30"
        use_shape = actual_h >= 6
        r_top = (draw_top + 1) >> 1
        r_bot = draw_bot >> 1
        actual_h_f = actual_h.to_f
        actual_w_f = actual_w.to_f

        c = start_x
        while c <= end_x
          if c >= 0 && c < view_w && dists[c] >= tz
            nx = (c - start_x) / actual_w_f

            r = r_top
            while r < r_bot
              vp0 = r << 1
              vp1 = vp0 + 1
              top_in = vp0 >= draw_top && vp0 < draw_bot
              bot_in = vp1 >= draw_top && vp1 < draw_bot

              if top_in || bot_in
                if use_shape
                  ny0 = top_in ? (vp0 - draw_top) / actual_h_f : nil
                  ny1 = bot_in ? (vp1 - draw_top) / actual_h_f : nil
                  top_color = ny0 ? Sprite.for(sprite_id, nx, ny0) : nil
                  bot_color = ny1 ? Sprite.for(sprite_id, nx, ny1) : nil
                  if top_color || bot_color
                    pixels[vp0][c] = top_color if top_color
                    pixels[vp1][c] = bot_color if bot_color
                  end
                else
                  pixels[vp0][c] = fallback_color if top_in
                  pixels[vp1][c] = fallback_color if bot_in
                end
              end
              r += 1
            end
          end
          c += 1
        end

        next unless e.max_hp > 1

        bar_row = r_top - 1
        next unless bar_row >= 0 && bar_row < view_h

        bar_w = actual_w > 2 ? actual_w : 2
        bar_sx = sx - bar_w / 2
        bar_sx = 0 if bar_sx < 0
        bar_ex = bar_sx + bar_w - 1
        bar_ex = view_w_last if bar_ex > view_w_last
        hp_pct = e.hp.to_f / e.max_hp
        filled = (hp_pct * (bar_ex - bar_sx + 1)).ceil
        bar_vp0 = bar_row << 1
        bar_vp1 = bar_vp0 + 1
        c = bar_sx
        while c <= bar_ex
          if c >= 0 && c < view_w && dists[c] >= tz
            ci = c - bar_sx
            color = ci < filled ? "0;200;0" : "200;0;0"
            pixels[bar_vp0][c] = color
            pixels[bar_vp1][c] = color
          end
          c += 1
        end
      end

      # Render weapon drops
      @drop_sprites.clear
      drops.each do |d|
        ex = d.x - player_x
        ey = d.y - player_y
        tx = inv * (dy * ex - dx * ey)
        tz = inv * (-py * ex + px * ey)
        next if tz < 0.2

        @drop_sprites << [tz, tx, d]
      end
      @drop_sprites.sort! { |a, b| b[0] <=> a[0] }

      @drop_sprites.each do |tz, tx, d|
        sx = (half_view_w * (1 + tx / tz)).to_i
        sprite_h = (virt_h / tz * 0.3).to_i.clamp(2, half_virt_h)
        ground = (half_virt_h + virt_h / tz * 0.35).to_i
        draw_bot = ground < virt_h ? ground : virt_h
        draw_top = draw_bot - sprite_h
        draw_top = 0 if draw_top < 0
        sprite_w = (sprite_h / 2).clamp(1, 6)
        start_x = sx - sprite_w / 2
        start_x = 0 if start_x < 0
        end_x = sx + sprite_w / 2
        end_x = view_w_last if end_x > view_w_last

        color = d.sprite_color
        r_top = (draw_top + 1) >> 1
        r_bot = draw_bot >> 1

        c = start_x
        while c <= end_x
          if c >= 0 && c < view_w && dists[c] >= tz
            r = r_top
            while r < r_bot
              if r >= 0 && r < view_h
                vp0 = r << 1
                vp1 = vp0 + 1
                top_in = vp0 >= draw_top && vp0 < draw_bot
                bot_in = vp1 >= draw_top && vp1 < draw_bot
                if top_in || bot_in
                  pixels[vp0][c] = color if top_in
                  pixels[vp1][c] = color if bot_in
                end
              end
              r += 1
            end
          end
          c += 1
        end
      end

      # Render projectiles
      @proj_sprites.sort! { |a, b| b[0] <=> a[0] }
      @proj_sprites.each do |tz, tx, p|
        sx = (half_view_w * (1 + tx / tz)).to_i
        pw = (4.0 / tz).ceil.clamp(1, 5)
        ph = (virt_h / tz * 0.15).ceil.clamp(2, 6)
        draw_top = half_virt_h - ph / 2
        draw_top = 0 if draw_top < 0
        draw_bot = half_virt_h + ph / 2
        draw_bot = draw_top + 2 if draw_bot < draw_top + 2
        draw_bot = virt_h if draw_bot > virt_h
        start_x = sx - pw / 2
        start_x = 0 if start_x < 0
        end_x = sx + pw / 2
        end_x = view_w_last if end_x > view_w_last
        proj_color = p.type == :executor ? "94;94;255" : "255;210;80"
        r_top = (draw_top + 1) >> 1
        r_bot = draw_bot >> 1
        r_bot = r_top + 1 if r_bot < r_top + 1

        c = start_x
        while c <= end_x
          if c >= 0 && c < view_w && dists[c] >= tz
            r = r_top
            while r < r_bot
              if r >= 0 && r < view_h
                vp0 = r << 1
                vp1 = vp0 + 1
                top_in = vp0 >= draw_top && vp0 < draw_bot
                bot_in = vp1 >= draw_top && vp1 < draw_bot
                if top_in || bot_in
                  pixels[vp0][c] = proj_color if top_in
                  pixels[vp1][c] = proj_color if bot_in
                end
              end
              r += 1
            end
          end
          c += 1
        end
      end
    end

    def overlay_allies_3d(pixels, view_h, view_w, dists, player, allies)
      dx = Math.cos(player.angle)
      dy = Math.sin(player.angle)
      px = -dy * Math.tan(Config::FOV / 2.0)
      py = dx * Math.tan(Config::FOV / 2.0)
      virt_h = view_h * 2
      inv = 1.0 / (px * dy - py * dx)

      @ally_sprites.clear
      allies.each do |ally|
        ex = ally.x - player.x
        ey = ally.y - player.y
        tx = inv * (dy * ex - dx * ey)
        tz = inv * (-py * ex + px * ey)
        next if tz < 0.2

        @ally_sprites << [tz, tx, ally]
      end
      @ally_sprites.sort! { |a, b| b[0] <=> a[0] }

      @ally_sprites.each do |tz, tx, ally|
        sx = ((view_w / 2.0) * (1 + tx / tz)).to_i
        sprite_h = (virt_h / tz).to_i
        draw_top = [(virt_h / 2 - sprite_h / 2), 0].max
        draw_bot = [(virt_h / 2 + sprite_h / 2), virt_h].min
        sprite_w = (sprite_h / 2.0).to_i
        start_x = [sx - sprite_w / 2, 0].max
        end_x   = [sx + sprite_w / 2, view_w - 1].min

        actual_h = draw_bot - draw_top
        actual_w = end_x - start_x + 1
        next if actual_h < 1 || actual_w < 1

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

              pixels[vp0][c] = top_color if top_color
              pixels[vp1][c] = bot_color if bot_color
            else
              pixels[vp0][c] = "70;210;255" if top_in
              pixels[vp1][c] = "70;210;255" if bot_in
            end
          end
        end

        bar_row = (draw_top / 2.0).ceil - 1
        next unless bar_row >= 0 && bar_row < view_h

        bar_w = [actual_w, 2].max
        bar_sx = [sx - bar_w / 2, 0].max
        bar_ex = [bar_sx + bar_w - 1, view_w - 1].min
        total = ally.shield + ally.health
        max_total = Config::SHIELD_MAX + Config::HEALTH_MAX
        hp_pct = total.to_f / max_total
        filled = (hp_pct * (bar_ex - bar_sx + 1)).ceil
        bar_sx.upto(bar_ex) do |c|
          next if c < 0 || c >= view_w
          next if dists[c] < tz

          ci = c - bar_sx
          color = ci < filled ? "0;180;255" : "80;20;20"
          pixels[bar_row * 2][c] = color
          pixels[bar_row * 2 + 1][c] = color
        end
      end
    end

    def overlay_damage_flash(pixels, view_h, view_w, player)
      return unless player.damage_flash > 0

      intensity = player.damage_flash * 60
      flash_w = 2
      color = "#{intensity};0;0"

      view_h.times do |r|
        vp0 = r * 2
        vp1 = vp0 + 1
        flash_w.times do |offset|
          left = offset
          right = view_w - flash_w + offset
          pixels[vp0][left] = color if left.between?(0, view_w - 1)
          pixels[vp1][left] = color if left.between?(0, view_w - 1)
          pixels[vp0][right] = color if right.between?(0, view_w - 1)
          pixels[vp1][right] = color if right.between?(0, view_w - 1)
        end
      end
    end

    def render_crosshair(buf, view_h, view_w, cols, player)
      cr = 3 + (view_h / 2)
      cc = view_w / 2 + 1
      buf << "\e[#{cr};#{cc}H\e[97m+\e[0m"

      return unless player.fire_flash > 0

      hw = [player.fire_flash * 4, view_w / 4].min
      fs = [cc - hw, 1].max
      fe = [cc + hw, cols].min
      buf << "\e[#{cr};#{fs}H\e[93m#{"*" * (fe - fs + 1)}\e[0m"
    end

    def bg_only?(color)
      color.is_a?(Integer)
    end

    def ansi_fg(color)
      if color.is_a?(Integer)
        FG_256[color]
      else
        @fg_truecolor_cache[color] ||= "\e[38;2;#{color}m".freeze
      end
    end

    def ansi_bg(color)
      if color.is_a?(Integer)
        BG_256[color]
      else
        @bg_truecolor_cache[color] ||= "\e[48;2;#{color}m".freeze
      end
    end
  end
end
