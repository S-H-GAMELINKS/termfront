# frozen_string_literal: true

module Termfront
  class Game
    def initialize
      @stdout = STDOUT
      @audio = AudioManager.new
      @renderer = Renderer.new(@stdout)
      @input = Input.new
      @scene_player = ScenePlayer.new(@stdout, audio: @audio)
      @demo_player = DemoPlayer.new(@stdout, @renderer)
      @difficulty = nil
    end

    def start
      enter_alt_screen
      loop do
        reset_title_screen_state
        @input.clear
        title = TitleScreen.new(@stdout)
        @audio.play_bgm(:title)
        choice = title.show
        @audio.stop_bgm
        case choice
        when :singleplayer then run_singleplayer
        when :wavesfight   then run_wavesfight
        when :campaign     then run_campaign
        when :pvp          then Network::Client.new(@stdout).run
        when :quit         then break
        end
      end
    rescue Interrupt
      # normal exit
    rescue StandardError => e
      @crash = e
    ensure
      @audio.close
      leave_alt_screen
      if @crash
        warn "#{@crash.class}: #{@crash.message}"
        @crash.backtrace.first(10).each { |l| warn "  #{l}" }
      end
    end

    private

    def run_singleplayer
      mission = Mission::Training.new
      load_mission(mission, nil)
      @audio.play_bgm(:mission)
      run_game_loop
    ensure
      @audio.stop_bgm
    end

    def run_campaign
      @difficulty = 1
      loop do
        choice = show_mission_select(missions: Mission::Base.campaign, title: "SELECT MISSION")
        if choice == :back
          clear_screen
          return
        end

        mission = Mission::Base.campaign[choice].new
        load_mission(mission, @difficulty)
        @audio.play_bgm(:mission)
        play_events(:mission_start, stdin: nil, title: mission.name)
        result = run_game_loop(show_complete_banner: false)
        return if result == :quit
        if result == :mission_complete
          play_events(:mission_complete, stdin: nil, title: mission.name)
          rows, cols = @stdout.winsize
          @audio.play_se(:mission_clear)
          @renderer.render_mission_complete(rows, cols)
          sleep 2
        end
        @audio.stop_bgm
      end
    ensure
      @audio.stop_bgm
      @difficulty = nil
    end

    def run_wavesfight
      @difficulty = 1
      missions = Mission::Base.wavesfight
      choice = show_mission_select(missions: missions, title: "SELECT WAVESFIGHT")
      if choice == :back
        clear_screen
        return
      end

      mission = missions[choice].new
      mode = show_wavesfight_mode_select
      if mode == :back
        clear_screen
        return
      end

      if mode == :coop
        Network::WavesfightClient.new(@stdout).run(mission_id: mission.id, difficulty: @difficulty)
        return
      end

      load_mission(mission, @difficulty)
      @audio.play_bgm(:mission)
      @wave = 0
      start_wavesfight_wave
      run_wavesfight_loop
    ensure
      @audio.stop_bgm
      @difficulty = nil
      @wave = nil
    end

    def load_mission(mission, difficulty_index)
      @mission = mission
      @map = mission.build_map
      weapons = mission.build_weapons
      x, y, angle = mission.spawn
      @player = Player.new(x: x, y: y, angle: angle, weapons: weapons)
      @enemies = mission.build_enemies(difficulty_index)
      @projectiles = []
      @player.drops = []
      @terminals = mission.build_terminals
      @event_runtime = Mission::EventRuntime.new(mission.event_definitions)
    end

    def run_game_loop(show_complete_banner: true)
      STDIN.raw do |stdin|
        last_time = clock

        loop do
          now = clock
          dt = now - last_time
          last_time = now

          keys = @input.process(stdin, player: @player)
          return :quit if @input.key?(:q) || @input.key?(:esc)

          if handle_player_actions(keys, stdin)
            last_time = clock
            next
          end

          update(dt)
          @renderer.render(
            player: @player, map: @map,
            enemies: @enemies, projectiles: @projectiles,
            drops: @player.drops, terminals: @terminals
          )

          if @player.dead
            rows, cols = @stdout.winsize
            @renderer.render_game_over(rows, cols)
            sleep 2
            return :dead
          end

          if @enemies.all? { |e| !e.alive }
            if show_complete_banner
              rows, cols = @stdout.winsize
              @renderer.render_mission_complete(rows, cols)
              sleep 2
            end
            return :mission_complete
          end

          cap_frame(now)
        end
      end
    end

    def run_wavesfight_loop
      STDIN.raw do |stdin|
        last_time = clock

        loop do
          now = clock
          dt = now - last_time
          last_time = now

          keys = @input.process(stdin, player: @player)
          return :quit if @input.key?(:q) || @input.key?(:esc)

          if handle_player_actions(keys, stdin)
            last_time = clock
            next
          end

          update(dt)
          @renderer.render(
            player: @player, map: @map,
            enemies: @enemies, projectiles: @projectiles,
            drops: @player.drops, terminals: @terminals,
            status_line: "  WAVE #{@wave}  #{Enemy::Base::DIFFICULTIES[@difficulty][:name]}"
          )

          if @player.dead
            rows, cols = @stdout.winsize
            @renderer.render_centered_message(rows, cols, "DOWN AT WAVE #{@wave}", "\e[1;91m")
            sleep 2
            return :dead
          end

          if @enemies.all? { |e| !e.alive }
            show_wave_clear
            start_wavesfight_wave
            last_time = clock
          end

          cap_frame(now)
        end
      end
    end

    def handle_player_actions(keys, stdin)
      if keys.include?(:t)
        @player.swap_weapon
      end

      if keys.include?(:e)
        terminal = nearest_terminal
        if terminal
          play_terminal_event(terminal, stdin)
          return true
        end

        @player.try_pickup
      end

      return false unless keys.include?(:space)

      weapon = @player.current_weapon
      return false unless weapon.can_fire?(@player.last_fire, @player.game_time)
      return false unless weapon.infinite_ammo? || (weapon.ammo && weapon.ammo > 0)

      @player.fire_flash = 4
      weapon.consume_ammo!
      @player.last_fire = @player.game_time
      @audio.play_se(:shoot)
      false
    end

    def nearest_terminal
      @terminals
        .map { |terminal| [terminal, (terminal[:x] - @player.x)**2 + (terminal[:y] - @player.y)**2] }
        .select { |_, distance_sq| distance_sq < Config::TERMINAL_USE_RADIUS**2 }
        .min_by { |_, distance_sq| distance_sq }
        &.first
    end

    def play_terminal_event(terminal, stdin)
      events = @event_runtime.trigger(:terminal_used, terminal_id: terminal[:id])
      actions = if events.empty?
                  [{ type: :text, text: "TERMINAL OFFLINE\nNo readable data remains." }]
                else
                  events.flat_map { |event| event[:actions] }
                end
      @input.clear
      @audio.play_se(:terminal)
      play_actions(actions, title: "Terminal", stdin: stdin)
      @input.clear
    end

    def play_events(type, stdin:, title:)
      events = @event_runtime.trigger(type)
      return if events.empty?

      @input.clear
      events.each do |event|
        play_actions(event[:actions], title: title, stdin: stdin)
      end
      @input.clear
    end

    def play_actions(actions, title:, stdin:)
      buffer = []

      actions.each do |action|
        if action[:type] == :demo
          unless buffer.empty?
            @scene_player.play(buffer, title: title, stdin: stdin)
            buffer.clear
          end
          @demo_player.play(action, mission: @mission, stdin: stdin)
        else
          buffer << action
        end
      end

      return if buffer.empty?

      @scene_player.play(buffer, title: title, stdin: stdin)
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

      @player.process_fire(@enemies, @map) if @player.fire_flash == 4
      @player.fire_flash -= 1 if @player.fire_flash > 0

      @enemies.each do |e|
        e.update(dt, @player, @projectiles, @map, @player.game_time, difficulty: @difficulty)
      end

      @projectiles.reject! do |p|
        p.update(dt)
        if p.hit_wall?(@map)
          true
        elsif p.hit_player?(@player.x, @player.y)
          enemy_klass = Enemy::Base.registry[p.type]
          dmg = enemy_klass ? enemy_klass.allocate.send(:damage) : 10
          @player.apply_damage(dmg)
          @audio.play_se(:damage)
          true
        else
          false
        end
      end

      relocate_drops_off_terminals

      @player.update_shield(dt, @stdout, audio: @audio)
    end

    def relocate_drops_off_terminals
      return if @terminals.empty? || @player.drops.empty?

      @player.drops.each do |drop|
        terminal = @terminals.find do |candidate|
          same_map_cell?(drop.x, drop.y, candidate[:x], candidate[:y])
        end
        next unless terminal

        fallback = find_drop_slot_near(terminal[:x], terminal[:y])
        next unless fallback

        drop.x = fallback[0]
        drop.y = fallback[1]
      end
    end

    def find_drop_slot_near(x, y)
      [
        [0.0, -0.9], [0.9, 0.0], [0.0, 0.9], [-0.9, 0.0],
        [0.9, -0.9], [0.9, 0.9], [-0.9, 0.9], [-0.9, -0.9]
      ].each do |dx, dy|
        nx = x + dx
        ny = y + dy
        next if @map.blocked?(nx, ny, 0.15)
        next if @terminals.any? { |terminal| same_map_cell?(nx, ny, terminal[:x], terminal[:y]) }

        return [nx, ny]
      end

      nil
    end

    def same_map_cell?(ax, ay, bx, by)
      ax.floor == bx.floor && ay.floor == by.floor
    end

    def start_wavesfight_wave
      @wave += 1
      @difficulty = [1 + ((@wave - 1) / 3), Enemy::Base::DIFFICULTIES.size - 1].min
      @enemies = build_wavesfight_enemies(@wave, @difficulty)
      replenish_wavesfight_loadout
      @projectiles.clear

      rows, cols = @stdout.winsize
      @renderer.render_centered_message(rows, cols, "WAVE #{@wave}", "\e[1;93m")
      sleep 1
    end

    def build_wavesfight_enemies(wave, difficulty_index)
      enemies = @mission.build_enemies(difficulty_index)
      bonus_count = (wave - 1) * 2
      enemies + Enemy::Base.generate_extras(@mission.enemy_defs, bonus_count, difficulty_index)
    end

    def replenish_wavesfight_loadout
      @player.shield = Config::SHIELD_MAX
      @player.health = [@player.health + 20.0, Config::HEALTH_MAX].min
      @player.last_damage = -Config::SHIELD_DELAY
      @player.dead = false

      @player.weapons.each do |weapon|
        next unless weapon.max_ammo

        refill = [weapon.max_ammo / 2, 1].max
        weapon.ammo = [weapon.ammo + refill, weapon.max_ammo].min
      end
    end

    def show_wave_clear
      rows, cols = @stdout.winsize
      @renderer.render_centered_message(rows, cols, "WAVE #{@wave} CLEAR", "\e[1;92m")
      sleep 1
    end

    def show_wavesfight_mode_select
      selected = 0
      options = [
        ["SOLO", "Play local wavesfight"],
        ["CO-OP", "Queue for 2-player online co-op"]
      ]

      STDIN.raw do |stdin|
        loop do
          rows, cols = @stdout.winsize
          buf = TerminalOutput.begin_frame(home: true, clear: true)
          lines = Array.new(rows) { " " * cols }
          title = "WAVESFIGHT MODE"
          tc = [(cols - title.size) / 2 + 1, 1].max
          lines[2] = TerminalOutput.fit_ansi("#{" " * (tc - 1)}\e[1;38;2;120;140;255m#{title}\e[0m", cols)

          options.each_with_index do |(label, desc), idx|
            row = 6 + idx * 3
            text = idx == selected ? "\e[1;97;44m  #{label.ljust(10)}  \e[0m" : "\e[97m  #{label.ljust(10)}  \e[0m"
            tc = [(cols - 14) / 2 + 1, 1].max
            dc = [(cols - desc.size) / 2 + 1, 1].max
            lines[row - 1] = TerminalOutput.fit_ansi("#{" " * (tc - 1)}#{text}", cols)
            lines[row] = TerminalOutput.fit_ansi("#{" " * (dc - 1)}\e[38;2;160;160;180m#{desc}\e[0m", cols)
          end

          hint = "Up/Down: Select   Enter: Confirm   Q/Esc: Back"
          hc = [(cols - hint.size) / 2 + 1, 1].max
          lines[rows - 3] = TerminalOutput.fit_ansi("#{" " * (hc - 1)}\e[38;2;100;100;120m#{hint}\e[0m", cols)

          lines.each_with_index do |line, index|
            buf << line
            buf << "\r\n" if index < rows - 1
          end
          buf << TerminalOutput.end_frame
          TerminalOutput.write_all(@stdout, buf)

          next unless IO.select([stdin], nil, nil, Config::FRAME_DT)

          begin
            ch = stdin.read_nonblock(64)
            i = 0
            while i < ch.bytesize
              b = ch.getbyte(i)
              if b == 27 && ch.getbyte(i + 1) == 91
                code = ch.getbyte(i + 2)
                case code
                when 65 then selected = (selected - 1) % options.size
                when 66 then selected = (selected + 1) % options.size
                end
                i += 3
              elsif [13, 10].include?(b)
                return selected.zero? ? :solo : :coop
              elsif [113, 81, 27].include?(b)
                return :back
              else
                i += 1
              end
            end
          rescue IO::WaitReadable
          end
        end
      end
    end

    def show_mission_select(missions:, title:)
      selected = 0
      TerminalOutput.write_all(@stdout, TerminalOutput.begin_frame(home: true, clear: true) + TerminalOutput.end_frame)

      STDIN.raw do |stdin|
        loop do
          now = clock
          render_mission_select(selected, missions, title)

          while IO.select([stdin], nil, nil, 0)
            begin
              ch = stdin.read_nonblock(64)
              i = 0
              while i < ch.bytesize
                b = ch.getbyte(i)
                if b == 27 && ch.getbyte(i + 1) == 91
                  code = ch.getbyte(i + 2)
                  case code
                  when 65 then selected = (selected - 1) % missions.size
                  when 66 then selected = (selected + 1) % missions.size
                  when 68 then @difficulty = (@difficulty - 1) % Enemy::Base::DIFFICULTIES.size
                  when 67 then @difficulty = (@difficulty + 1) % Enemy::Base::DIFFICULTIES.size
                  end
                  i += 3
                elsif [13, 10].include?(b)
                  return selected
                elsif b >= 49 && b <= 49 + missions.size - 1
                  return b - 49
                elsif [113, 81, 27].include?(b)
                  return :back
                else
                  i += 1
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

    def render_mission_select(selected, missions, title)
      rows, cols = @stdout.winsize
      buf = TerminalOutput.begin_frame(home: true)
      lines = Array.new(rows) { " " * cols }

      tc = [(cols - title.size) / 2 + 1, 1].max
      lines[1] = TerminalOutput.fit_ansi("#{" " * (tc - 1)}\e[1;38;2;120;140;255m#{title}\e[0m", cols)

      diff = Enemy::Base::DIFFICULTIES[@difficulty]
      diff_colors = ["\e[92m", "\e[93m", "\e[38;2;255;165;0m", "\e[91m"]
      diff_label = "< #{diff[:name]} >"
      dc = [(cols - diff_label.size) / 2 + 1, 1].max
      lines[2] = TerminalOutput.fit_ansi("#{" " * (dc - 1)}#{diff_colors[@difficulty]}#{diff_label}\e[0m", cols)

      missions.each_with_index do |klass, i|
        m = klass.new
        row = 5 + i * 2
        label = "  #{i + 1}. #{m.name}"
        lc = [(cols - 40) / 2 + 1, 1].max
        text = if i == selected
                 "\e[1;97;44m> #{label.strip.ljust(38)}\e[0m"
               else
                 "\e[97m  #{label.strip.ljust(38)}\e[0m"
               end
        lines[row - 1] = TerminalOutput.fit_ansi("#{" " * (lc - 1)}#{text}", cols)
      end

      brief_row = 5 + missions.size * 2 + 1
      m = missions[selected].new
      briefing = m.briefing
      bc = [(cols - briefing.size) / 2 + 1, 1].max
      lines[brief_row - 1] = TerminalOutput.fit_ansi("#{" " * (bc - 1)}\e[38;2;180;180;200m#{briefing}\e[0m", cols)

      info_row = brief_row + 2
      edefs = m.enemy_defs
      base_crawler = edefs.count { |e| e[4] == :crawler }
      base_executor = edefs.count { |e| e[4] == :executor }
      extra = diff[:extra_enemies]
      extra_crawler = 0
      extra_executor = 0
      extra.times do |i|
        src_type = edefs[i % edefs.size][4]
        src_type == :crawler ? (extra_crawler += 1) : (extra_executor += 1)
      end
      crawler_c = base_crawler + extra_crawler
      executor_c = base_executor + extra_executor
      info = "Enemies: #{crawler_c} Crawler#{crawler_c != 1 ? "s" : ""}"
      info += ", #{executor_c} Executor#{executor_c != 1 ? "s" : ""}" if executor_c > 0
      info += "  |  HP x#{diff[:hp_mult]}"
      ic = [(cols - info.size) / 2 + 1, 1].max
      lines[info_row - 1] = TerminalOutput.fit_ansi("#{" " * (ic - 1)}\e[38;2;140;140;160m#{info}\e[0m", cols)

      ctrl_row = info_row + 2
      ctrl = "Up/Down: Select   Left/Right: Difficulty   Enter/1-5: Start   Q: Back"
      cc = [(cols - ctrl.size) / 2 + 1, 1].max
      lines[ctrl_row - 1] = TerminalOutput.fit_ansi("#{" " * (cc - 1)}\e[38;2;100;100;120m#{ctrl}\e[0m", cols)

      lines.each_with_index do |line, index|
        buf << line
        buf << "\r\n" if index < rows - 1
      end

      buf << TerminalOutput.end_frame
      TerminalOutput.write_all(@stdout, buf)
    end

    def enter_alt_screen
      print "\e[?1049h\e[?25l"
    end

    def leave_alt_screen
      print "\e[?25h\e[?1049l"
    end

    def clear_screen
      TerminalOutput.write_all(@stdout, TerminalOutput.begin_frame(home: true, clear: true) + TerminalOutput.end_frame)
    end

    def reset_title_screen_state
      TerminalOutput.write_all(@stdout, "\e[?25h\e[?1049l\e[?1049h\e[?25l\e[H\e[2J")
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
