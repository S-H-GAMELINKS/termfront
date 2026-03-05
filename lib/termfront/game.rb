# frozen_string_literal: true

module Termfront
  class Game
    def initialize
      @stdout = STDOUT
      @renderer = Renderer.new(@stdout)
      @input = Input.new
      @difficulty = nil
    end

    def start
      enter_alt_screen
      loop do
        title = TitleScreen.new(@stdout)
        case title.show
        when :singleplayer then run_singleplayer
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
      run_game_loop
    end

    def run_campaign
      @difficulty = 1
      loop do
        choice = show_mission_select
        return if choice == :back

        mission = Mission::Base.campaign[choice].new
        load_mission(mission, @difficulty)
        result = run_game_loop
        return if result == :quit
      end
    ensure
      @difficulty = nil
    end

    def load_mission(mission, difficulty_index)
      @map = mission.build_map
      weapons = mission.build_weapons
      x, y, angle = mission.spawn
      @player = Player.new(x: x, y: y, angle: angle, weapons: weapons)
      @enemies = mission.build_enemies(difficulty_index)
      @projectiles = []
      @player.drops = []
    end

    def run_game_loop
      STDIN.raw do |stdin|
        last_time = clock

        loop do
          now = clock
          dt = now - last_time
          last_time = now

          @input.process(stdin, player: @player)
          return :quit if @input.key?(:q) || @input.key?(:esc)

          update(dt)
          @renderer.render(
            player: @player, map: @map,
            enemies: @enemies, projectiles: @projectiles,
            drops: @player.drops
          )

          if @player.dead
            rows, cols = @stdout.winsize
            @renderer.render_game_over(rows, cols)
            sleep 2
            return :dead
          end

          if @enemies.all? { |e| !e.alive }
            rows, cols = @stdout.winsize
            @renderer.render_mission_complete(rows, cols)
            sleep 2
            return :mission_complete
          end

          cap_frame(now)
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
          true
        else
          false
        end
      end

      @player.update_shield(dt, @stdout)
    end

    def show_mission_select
      selected = 0
      missions = Mission::Base.campaign
      @stdout.syswrite("\e[?2026h\e[H\e[2J\e[?2026l")

      STDIN.raw do |stdin|
        loop do
          now = clock
          render_mission_select(selected, missions)

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

    def render_mission_select(selected, missions)
      rows, cols = @stdout.winsize
      buf = +"\e[?2026h\e[H"

      title = "SELECT MISSION"
      tc = [(cols - title.size) / 2 + 1, 1].max
      buf << "\e[2;#{tc}H\e[1;38;2;120;140;255m#{title}\e[0m"

      diff = Enemy::Base::DIFFICULTIES[@difficulty]
      diff_colors = ["\e[92m", "\e[93m", "\e[38;2;255;165;0m", "\e[91m"]
      diff_label = "< #{diff[:name]} >"
      dc = [(cols - diff_label.size) / 2 + 1, 1].max
      buf << "\e[3;1H\e[K"
      buf << "\e[3;#{dc}H#{diff_colors[@difficulty]}#{diff_label}\e[0m"

      missions.each_with_index do |klass, i|
        m = klass.new
        row = 5 + i * 2
        label = "  #{i + 1}. #{m.name}"
        lc = [(cols - 40) / 2 + 1, 1].max
        buf << if i == selected
                 "\e[#{row};#{lc}H\e[1;97;44m> #{label.strip.ljust(38)}\e[0m"
               else
                 "\e[#{row};#{lc}H\e[97m  #{label.strip.ljust(38)}\e[0m"
               end
      end

      brief_row = 5 + missions.size * 2 + 1
      m = missions[selected].new
      briefing = m.briefing
      bc = [(cols - briefing.size) / 2 + 1, 1].max
      buf << "\e[#{brief_row};1H\e[K"
      buf << "\e[#{brief_row};#{bc}H\e[38;2;180;180;200m#{briefing}\e[0m"

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
      buf << "\e[#{info_row};1H\e[K"
      buf << "\e[#{info_row};#{ic}H\e[38;2;140;140;160m#{info}\e[0m"

      ctrl_row = info_row + 2
      ctrl = "Up/Down: Select   Left/Right: Difficulty   Enter/1-5: Start   Q: Back"
      cc = [(cols - ctrl.size) / 2 + 1, 1].max
      buf << "\e[#{ctrl_row};1H\e[K"
      buf << "\e[#{ctrl_row};#{cc}H\e[38;2;100;100;120m#{ctrl}\e[0m"

      (ctrl_row + 1).upto(rows) { |r| buf << "\e[#{r};1H\e[K" }

      buf << "\e[?2026l"
      @stdout.syswrite(buf)
    end

    def enter_alt_screen
      print "\e[?1049h\e[?25l"
    end

    def leave_alt_screen
      print "\e[?25h\e[?1049l"
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
