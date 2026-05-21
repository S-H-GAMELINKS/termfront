# frozen_string_literal: true

module Termfront
  class Renderer
    def initialize(stdout)
      @stdout = stdout
    end

    def render(player:, map:, enemies:, projectiles:, drops:, terminals: [], status_line: nil, allies: [])
      rows, cols = @stdout.winsize
      rows = [rows, 6].max
      cols = [cols, 20].max

      radar_h = Config::RADAR_RADIUS * 2 + 1
      view_h = [rows - 3 - radar_h, 4].max
      view_w = cols
      virt_h = view_h * 2

      dx = Math.cos(player.angle)
      dy = Math.sin(player.angle)
      plane_x = -dy * Math.tan(Config::FOV / 2.0)
      plane_y = dx * Math.tan(Config::FOV / 2.0)

      dists = Array.new(view_w)
      sides = Array.new(view_w)
      view_w.times do |c|
        cam = 2.0 * c / view_w - 1.0
        dists[c], sides[c] = cast_ray(map, player.x, player.y, dx + plane_x * cam, dy + plane_y * cam)
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
      pixels = build_view_pixels(virt_h, view_w, wtop, wbot, wcol)
      overlay_enemies_3d(pixels, view_h, view_w, dists, player, enemies, projectiles, drops)
      overlay_allies_3d(pixels, view_h, view_w, dists, player, allies)
      overlay_damage_flash(pixels, view_h, view_w, player)

      buf = TerminalOutput.begin_frame(home: true)

      render_hud(buf, cols, player, drops, terminals, status_line)
      render_view(buf, view_h, view_w, pixels)
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

    def render_hud(buf, cols, player, drops, terminals, status_line)
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
      buf << TerminalOutput.fit_ansi("#{" " * pad}#{shield_str}", cols) << "\r\n"

      weapon = player.current_weapon
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

      can_pickup = drops.any? { |d| d.in_range?(player.x, player.y) }
      can_use_terminal = terminals.any? do |terminal|
        (terminal[:x] - player.x)**2 + (terminal[:y] - player.y)**2 < Config::TERMINAL_USE_RADIUS**2
      end
      interact_str = if can_use_terminal
                       "\e[1;96m[E]Use Terminal\e[0m"
                     elsif can_pickup
                       "\e[1;93m[E]Pickup\e[0m"
                     else
                       "E:interact"
                     end

      line = "#{ammo_str}  T:swap  #{interact_str}  Space:fire"
      buf << TerminalOutput.fit_ansi(line, cols) << "\r\n"
    end

    def build_view_pixels(virt_h, view_w, wtop, wbot, wcol)
      pixels = Array.new(virt_h) { Array.new(view_w) }
      virt_h.times do |vr|
        row = pixels[vr]
        view_w.times do |c|
          row[c] = if vr < wtop[c]
                     Config::CEIL_C
                   elsif vr < wbot[c]
                     wcol[c]
                   else
                     Config::FLOOR_C
                   end
        end
      end
      pixels
    end

    def render_view(buf, view_h, view_w, pixels)
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
            if bg_only?(tc)
              if tc != pbg
                buf << ansi_bg(tc)
                pbg = tc
                pfg = nil
              end
              buf << " "
            else
              if tc != pfg || pbg
                buf << ansi_fg(tc)
                pfg = tc
                pbg = nil
              end
              buf << "\xE2\x96\x88"
            end
          else
            if tc != pfg || bc != pbg
              buf << ansi_fg(tc) << ansi_bg(bc)
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
      buf << ("\xE2\x94\x80" * cols)[0, cols * 3] << "\r\n"

      r = Config::RADAR_RADIUS
      diam = r * 2 + 1

      grid = Array.new(diam) { Array.new(diam, " ") }
      diam.times do |ry|
        diam.times do |rx|
          dx = rx - r
          dy = ry - r
          d2 = dx * dx + dy * dy
          if d2 <= r * r
            grid[ry][rx] = "."
          elsif d2 <= (r + 1) * (r + 1)
            grid[ry][rx] = "#"
          end
        end
      end
      grid[r][r] = "^"

      cos_a = Math.cos(-player.angle + Math::PI / 2)
      sin_a = Math.sin(-player.angle + Math::PI / 2)
      enemy_cells = {}
      enemies.each do |e|
        next unless e.alive

        ex = e.x - player.x
        ey = e.y - player.y
        dist = Math.sqrt(ex * ex + ey * ey)
        next if dist > Config::RADAR_RANGE

        rx = -(ex * cos_a - ey * sin_a)
        ry = -(ex * sin_a + ey * cos_a)
        sx = r + (rx / Config::RADAR_RANGE * r).round
        sy = r + (ry / Config::RADAR_RANGE * r).round
        next unless sx.between?(0, diam - 1) && sy.between?(0, diam - 1)

        d2 = (sx - r)**2 + (sy - r)**2
        next if d2 > r * r

        enemy_cells[[sy, sx]] = e.sprite_id
      end

      drop_cells = {}
      drops.each do |d|
        ex = d.x - player.x
        ey = d.y - player.y
        dist = Math.sqrt(ex * ex + ey * ey)
        next if dist > Config::RADAR_RANGE

        rx = -(ex * cos_a - ey * sin_a)
        ry = -(ex * sin_a + ey * cos_a)
        sx = r + (rx / Config::RADAR_RANGE * r).round
        sy = r + (ry / Config::RADAR_RANGE * r).round
        next unless sx.between?(0, diam - 1) && sy.between?(0, diam - 1)

        d2 = (sx - r)**2 + (sy - r)**2
        next if d2 > r * r

        drop_cells[[sy, sx]] = d
      end

      terminal_cells = {}
      terminals.each do |terminal|
        ex = terminal[:x] - player.x
        ey = terminal[:y] - player.y
        dist = Math.sqrt(ex * ex + ey * ey)
        next if dist > Config::RADAR_RANGE

        rx = -(ex * cos_a - ey * sin_a)
        ry = -(ex * sin_a + ey * cos_a)
        sx = r + (rx / Config::RADAR_RANGE * r).round
        sy = r + (ry / Config::RADAR_RANGE * r).round
        next unless sx.between?(0, diam - 1) && sy.between?(0, diam - 1)

        d2 = (sx - r)**2 + (sy - r)**2
        next if d2 > r * r

        terminal_cells[[sy, sx]] = terminal
      end

      ally_cells = {}
      allies.each do |ally|
        ex = ally.x - player.x
        ey = ally.y - player.y
        dist = Math.sqrt(ex * ex + ey * ey)
        next if dist > Config::RADAR_RANGE

        rx = -(ex * cos_a - ey * sin_a)
        ry = -(ex * sin_a + ey * cos_a)
        sx = r + (rx / Config::RADAR_RANGE * r).round
        sy = r + (ry / Config::RADAR_RANGE * r).round
        next unless sx.between?(0, diam - 1) && sy.between?(0, diam - 1)

        d2 = (sx - r)**2 + (sy - r)**2
        next if d2 > r * r

        ally_cells[[sy, sx]] = true
      end

      alive_count = enemies.count(&:alive)
      total_count = enemies.size
      info_lines = [
        "Enemies: #{alive_count}/#{total_count}",
        "Heading: #{format("%.0f", (player.angle % (Math::PI * 2)) * 180 / Math::PI)}\xC2\xB0",
        "Pos: (#{"%.1f" % player.x}, #{"%.1f" % player.y})  T:terminal"
      ]

      radar_h.times do |row|
        line = +""
        if row < diam
          line << "  "
          diam.times do |cx|
            if (etype = enemy_cells[[row, cx]])
              ec = etype == :executor ? "\e[95m" : "\e[91m"
              line << "#{ec}*\e[0m"
            elsif ally_cells[[row, cx]]
              line << "\e[96m+\e[0m"
            elsif (drop = drop_cells[[row, cx]])
              dc = drop.type.to_s.start_with?("shock") ? "\e[96m" : "\e[93m"
              dl = Weapon::Base.registry[drop.type].new.name[0]
              line << "#{dc}#{dl}\e[0m"
            elsif terminal_cells[[row, cx]]
              line << "\e[96mT\e[0m"
            elsif row == r && cx == r
              line << "\e[92m^\e[0m"
            elsif grid[row][cx] == "#"
              line << "\e[90m#\e[0m"
            else
              line << grid[row][cx]
            end
          end
          line << (row < info_lines.size ? "    #{info_lines[row]}" : "")
        end
        buf << TerminalOutput.fit_ansi(line, cols)
        buf << "\r\n" if row < radar_h - 1
      end
    end

    def overlay_enemies_3d(pixels, view_h, view_w, dists, player, enemies, projectiles, drops)
      dx = Math.cos(player.angle)
      dy = Math.sin(player.angle)
      px = -dy * Math.tan(Config::FOV / 2.0)
      py = dx * Math.tan(Config::FOV / 2.0)
      virt_h = view_h * 2
      inv = 1.0 / (px * dy - py * dx)

      sprites = []
      enemies.each do |e|
        next unless e.alive

        ex = e.x - player.x
        ey = e.y - player.y
        tx = inv * (dy * ex - dx * ey)
        tz = inv * (-py * ex + px * ey)
        next if tz < 0.2

        sprites << [tz, tx, e]
      end

      proj_sprites = []
      projectiles.each do |p|
        ex = p.x - player.x
        ey = p.y - player.y
        tx = inv * (dy * ex - dx * ey)
        tz = inv * (-py * ex + px * ey)
        next if tz < 0.2

        proj_sprites << [tz, tx, p]
      end

      sprites.sort_by! { |s| -s[0] }

      sprites.each do |tz, tx, e|
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

        fallback_color = e.sprite_id == :executor ? "100;60;200" : "220;140;30"
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
              top_color = ny0 ? Sprite.for(e.sprite_id, nx, ny0) : nil
              bot_color = ny1 ? Sprite.for(e.sprite_id, nx, ny1) : nil
              next unless top_color || bot_color

              pixels[vp0][c] = top_color if top_color
              pixels[vp1][c] = bot_color if bot_color
            else
              pixels[vp0][c] = fallback_color if top_in
              pixels[vp1][c] = fallback_color if bot_in
            end
          end
        end

        next unless e.max_hp > 1

        bar_row = (draw_top / 2.0).ceil - 1
        next unless bar_row >= 0 && bar_row < view_h

        bar_w = [actual_w, 2].max
        bar_sx = [sx - bar_w / 2, 0].max
        bar_ex = [bar_sx + bar_w - 1, view_w - 1].min
        hp_pct = e.hp.to_f / e.max_hp
        filled = (hp_pct * (bar_ex - bar_sx + 1)).ceil
        bar_sx.upto(bar_ex) do |c|
          next if c < 0 || c >= view_w
          next if dists[c] < tz

          ci = c - bar_sx
          color = ci < filled ? "0;200;0" : "200;0;0"
          pixels[bar_row * 2][c] = color
          pixels[bar_row * 2 + 1][c] = color
        end
      end

      # Render weapon drops
      drop_sprites = []
      drops.each do |d|
        ex = d.x - player.x
        ey = d.y - player.y
        tx = inv * (dy * ex - dx * ey)
        tz = inv * (-py * ex + px * ey)
        next if tz < 0.2

        drop_sprites << [tz, tx, d]
      end
      drop_sprites.sort_by! { |s| -s[0] }

      drop_sprites.each do |tz, tx, d|
        sx = ((view_w / 2.0) * (1 + tx / tz)).to_i
        sprite_h = (virt_h / tz * 0.3).to_i.clamp(2, virt_h / 2)
        ground = (virt_h / 2 + virt_h / tz * 0.35).to_i
        draw_bot = [ground, virt_h].min
        draw_top = [draw_bot - sprite_h, 0].max
        sprite_w = (sprite_h / 2.0).to_i.clamp(1, 6)
        start_x = [sx - sprite_w / 2, 0].max
        end_x   = [sx + sprite_w / 2, view_w - 1].min

        color = d.sprite_color

        start_x.upto(end_x) do |c|
          next if c < 0 || c >= view_w
          next if dists[c] < tz

          r_top = (draw_top / 2.0).ceil
          r_bot = (draw_bot / 2.0).floor
          r_top.upto(r_bot - 1) do |r|
            next if r < 0 || r >= view_h

            vp0 = r * 2
            vp1 = r * 2 + 1
            top_in = vp0 >= draw_top && vp0 < draw_bot
            bot_in = vp1 >= draw_top && vp1 < draw_bot
            next unless top_in || bot_in

            pixels[vp0][c] = color if top_in
            pixels[vp1][c] = color if bot_in
          end
        end
      end

      # Render projectiles
      proj_sprites.sort_by! { |s| -s[0] }
      proj_sprites.each do |tz, tx, p|
        sx = ((view_w / 2.0) * (1 + tx / tz)).to_i
        pw = (4.0 / tz).ceil.clamp(1, 5)
        ph = (virt_h / tz * 0.15).ceil.clamp(2, 6)
        vmid = virt_h / 2
        draw_top = [(vmid - ph / 2), 0].max
        draw_bot = [(vmid + ph / 2).clamp(draw_top + 2, virt_h), virt_h].min
        start_x = [sx - pw / 2, 0].max
        end_x   = [sx + pw / 2, view_w - 1].min
        col_code = p.type == :executor ? "94" : "93"

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

            proj_color = col_code == "94" ? "94;94;255" : "255;210;80"
            pixels[vp0][c] = proj_color if top_in
            pixels[vp1][c] = proj_color if bot_in
          end
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

      sprites = []
      allies.each do |ally|
        ex = ally.x - player.x
        ey = ally.y - player.y
        tx = inv * (dy * ex - dx * ey)
        tz = inv * (-py * ex + px * ey)
        next if tz < 0.2

        sprites << [tz, tx, ally]
      end
      sprites.sort_by! { |s| -s[0] }

      sprites.each do |tz, tx, ally|
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
        "\e[38;5;#{color}m"
      else
        "\e[38;2;#{color}m"
      end
    end

    def ansi_bg(color)
      if color.is_a?(Integer)
        "\e[48;5;#{color}m"
      else
        "\e[48;2;#{color}m"
      end
    end
  end
end
