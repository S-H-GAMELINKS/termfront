# frozen_string_literal: true

module Termfront
  class TitleScreen
    DEMO_WAYPOINTS = [
      [2.5, 5.0], [7.0, 2.5], [11.0, 3.5], [13.0, 5.0],
      [13.0, 8.0], [10.0, 8.5], [5.0, 8.5], [2.5, 5.0]
    ].freeze

    def initialize(stdout)
      @stdout = stdout
      @title_spin = 0.0
      @demo_wp_idx = 0
      @demo_wp_t = 0.0
      @demo_fire = 0
    end

    def show
      @title_spin = 0.0
      @demo_wp_idx = 0
      @demo_wp_t = 0.0
      @demo_fire = 0

      TerminalOutput.write_all(@stdout, TerminalOutput.begin_frame(home: true, clear: true) + TerminalOutput.end_frame)

      STDIN.raw do |stdin|
        loop do
          now = clock
          @title_spin += 0.015

          render

          while IO.select([stdin], nil, nil, 0)
            begin
              ch = stdin.read_nonblock(64)
              ch.each_byte do |b|
                case b
                when 115, 83  then return :singleplayer
                when 99, 67   then return :campaign
                when 112, 80  then return :pvp
                when 113, 81, 27 then return :quit
                end
              end
            rescue IO::WaitReadable
              break
            end
          end

          spent = clock - now
          remain = Config::FRAME_DT - spent
          sleep(remain) if remain > 0
        end
      end
    end

    private

    def clock
      Process.clock_gettime(Process::CLOCK_MONOTONIC)
    end

    def render
      rows, cols = @stdout.winsize
      rows = [rows, 10].max
      cols = [cols, 20].max
      buf = TerminalOutput.begin_frame(home: true)
      lines = Array.new(rows) { " " * cols }

      reserved_rows = 7
      th = rows - reserved_rows
      th = 3 if th < 3
      th = rows - 3 if th >= rows
      th = 1 if th < 1
      tw = [cols, 20].max
      virt_h = th * 2
      color = Array.new(tw * virt_h, nil)

      mission = Mission::Base.campaign.first
      return unless mission

      m = mission.new
      demo_map = m.map_data.map { |r| r.is_a?(Array) ? r : r.chars }
      dm_h = demo_map.size
      dm_w = demo_map[0].size

      @demo_wp_t += Config::DEMO_SPEED
      if @demo_wp_t >= 1.0
        @demo_wp_t -= 1.0
        @demo_wp_idx = (@demo_wp_idx + 1) % DEMO_WAYPOINTS.size
      end
      wp_a = DEMO_WAYPOINTS[@demo_wp_idx]
      wp_b = DEMO_WAYPOINTS[(@demo_wp_idx + 1) % DEMO_WAYPOINTS.size]
      st = @demo_wp_t * @demo_wp_t * (3 - 2 * @demo_wp_t)
      cam_x = wp_a[0] + (wp_b[0] - wp_a[0]) * st
      cam_y = wp_a[1] + (wp_b[1] - wp_a[1]) * st

      dx = wp_b[0] - wp_a[0]
      dy = wp_b[1] - wp_a[1]
      cam_a = Math.atan2(dy, dx) + 0.15 * Math.sin(@title_spin * 1.7)

      bob = Math.sin(@title_spin * 4.0) * 0.4

      @demo_fire -= 1 if @demo_fire > 0
      @demo_fire = 4 if (@title_spin * 100).to_i % 120 == 0 && @demo_fire <= 0

      fov = Config::FOV
      half_fov = fov / 2.0
      dists = Array.new(tw, 100.0)
      horizon = (virt_h / 2 + bob).to_i

      ceil_c = "0;0;95"
      floor_c = "28;28;28"

      tw.times do |col|
        ray_a = cam_a - half_fov + fov * col.to_f / tw
        rd_x = Math.cos(ray_a)
        rd_y = Math.sin(ray_a)

        mx = cam_x.to_i
        my = cam_y.to_i
        dd_x = rd_x == 0 ? 1e30 : (1.0 / rd_x.abs)
        dd_y = rd_y == 0 ? 1e30 : (1.0 / rd_y.abs)
        if rd_x < 0
          step_x = -1
          sd_x = (cam_x - mx) * dd_x
        else
          step_x = 1
          sd_x = (mx + 1.0 - cam_x) * dd_x
        end
        if rd_y < 0
          step_y = -1
          sd_y = (cam_y - my) * dd_y
        else
          step_y = 1
          sd_y = (my + 1.0 - cam_y) * dd_y
        end
        side = 0
        32.times do
          if sd_x < sd_y
            sd_x += dd_x
            mx += step_x
            side = 0
          else
            sd_y += dd_y
            my += step_y
            side = 1
          end
          break if mx >= 0 && mx < dm_w && my >= 0 && my < dm_h && demo_map[my][mx] == "#"
          break if mx < 0 || mx >= dm_w || my < 0 || my >= dm_h
        end
        dist = side == 0 ? (mx - cam_x + (1 - step_x) / 2.0) / rd_x : (my - cam_y + (1 - step_y) / 2.0) / rd_y
        dist = dist.abs
        perp = dist * Math.cos(ray_a - cam_a)
        perp = 0.1 if perp < 0.1
        dists[col] = perp

        wall_h = (virt_h / perp).to_i
        draw_start = [horizon - wall_h / 2, 0].max
        draw_end   = [horizon + wall_h / 2, virt_h - 1].min

        wb = 255 - [[(dist * 2.5).to_i, 0].max, 19].min
        wb -= 3 if side == 1
        wb = wb.clamp(233, 255)
        grey = 8 + (wb - 232) * 10
        if @demo_fire > 0 && dist < 4.0
          flash = @demo_fire / 4.0 * (1.0 - dist / 4.0)
          rr = (grey + flash * 160).to_i.clamp(0, 255)
          gg = (grey + flash * 60).to_i.clamp(0, 255)
          wall_c = "#{rr};#{gg};#{grey}"
        else
          wall_c = "#{grey};#{grey};#{grey}"
        end

        virt_h.times do |vr|
          color[vr * tw + col] = if vr < draw_start
                                   ceil_c
                                 elsif vr <= draw_end
                                   wall_c
                                 else
                                   floor_c
                                 end
        end
      end

      # Demo enemies
      demo_enemies = m.enemy_defs
      ddx = Math.cos(cam_a)
      ddy = Math.sin(cam_a)
      ppx = -ddy * Math.tan(fov / 2.0)
      ppy = ddx * Math.tan(fov / 2.0)
      inv_det = 1.0 / (ppx * ddy - ppy * ddx)

      sprites = []
      demo_enemies.each do |sx, sy, ax, ay, type|
        seg_len = Math.sqrt((ax - sx)**2 + (ay - sy)**2) + 0.01
        period = seg_len / 1.5
        phase = (@title_spin * 0.5) % (period * 2)
        et = phase < period ? phase / period : 2.0 - phase / period
        ex = sx + (ax - sx) * et
        ey = sy + (ay - sy) * et

        rx = ex - cam_x
        ry = ey - cam_y
        tx = inv_det * (ddy * rx - ddx * ry)
        tz = inv_det * (-ppy * rx + ppx * ry)
        next if tz < 0.3

        sprites << [tz, tx, type]
      end
      sprites.sort_by! { |s| -s[0] }

      sprites.each do |tz, tx, type|
        scr_x = ((tw / 2.0) * (1 + tx / tz)).to_i
        sprite_h = (virt_h / tz).to_i
        draw_top = [(horizon - sprite_h / 2), 0].max
        draw_bot = [(horizon + sprite_h / 2), virt_h].min
        sprite_w = (sprite_h / 2.0).to_i
        start_x = [scr_x - sprite_w / 2, 0].max
        end_x   = [scr_x + sprite_w / 2, tw - 1].min

        actual_h = draw_bot - draw_top
        actual_w = end_x - start_x + 1
        next if actual_h < 1 || actual_w < 1

        use_shape = actual_h >= 6

        start_x.upto(end_x) do |c|
          next if c < 0 || c >= tw
          next if dists[c] < tz

          nx = (c - start_x).to_f / actual_w

          draw_top.upto(draw_bot - 1) do |vr|
            if use_shape
              ny = (vr - draw_top).to_f / actual_h
              sc = Sprite.for(type, nx, ny)
              next unless sc
            else
              sc = type == :executor ? "100;60;200" : "220;140;30"
            end
            color[vr * tw + c] = sc
          end
        end
      end

      # Half-block rendering
      th.times do |r|
        vp0 = r * 2
        vp1 = r * 2 + 1
        line = +""
        tw.times do |c|
          tc = color[vp0 * tw + c]
          bc = color[vp1 * tw + c]
          line << if tc && bc
                    if tc == bc
                      "\e[38;2;#{tc}m\xE2\x96\x88\e[0m"
                    else
                      "\e[38;2;#{tc};48;2;#{bc}m\xE2\x96\x80\e[0m"
                    end
                  elsif tc
                    "\e[38;2;#{tc}m\xE2\x96\x80\e[0m"
                  elsif bc
                    "\e[38;2;#{bc}m\xE2\x96\x84\e[0m"
                  else
                    " "
                  end
        end
        lines[r] = TerminalOutput.fit_ansi(line, cols)
      end

      # Title text
      title_row = [[th + 1, rows - 4].min, 1].max
      title = "T E R M F R O N T"
      sub   = "Terminal FPS"
      tc = [(cols - title.size) / 2 + 1, 1].max
      sc = [(cols - sub.size) / 2 + 1, 1].max
      lines[title_row - 1] = TerminalOutput.fit_ansi("#{" " * (tc - 1)}\e[1;38;2;120;140;255m#{title}\e[0m", cols)
      lines[title_row] = TerminalOutput.fit_ansi("#{" " * (sc - 1)}\e[38;2;80;80;120m#{sub}\e[0m", cols)

      # Menu items
      items = ["[P] PvP", "[C] Campaign", "[S] Training", "[Q] Quit"]
      items_count_for_menu = items.size
      menu_row = [[title_row + 2, rows - items_count_for_menu].min, 1].max
      items.each_with_index do |item, i|
        ic = [(cols - item.size) / 2 + 1, 1].max
        lines[menu_row + i - 1] = TerminalOutput.fit_ansi("#{" " * (ic - 1)}\e[97m#{item}\e[0m", cols)
      end

      lines.each_with_index do |line, index|
        buf << line
        buf << "\r\n" if index < rows - 1
      end

      buf << TerminalOutput.end_frame
      TerminalOutput.write_all(@stdout, buf)
    end
  end
end
