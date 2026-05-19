# frozen_string_literal: true

module Termfront
  class DemoPlayer
    DemoActor = Struct.new(:x, :y, :sprite_id, :alive, :hp, :max_hp, keyword_init: true)

    def initialize(stdout, renderer)
      @stdout = stdout
      @renderer = renderer
    end

    def play(action, mission:, stdin: nil)
      path = Array(action[:path])
      return if path.empty?

      duration = (action[:duration] || path.last[:t] || 0.0).to_f
      return if duration <= 0

      if stdin
        play_loop(stdin, action, mission, path, duration)
      else
        STDIN.raw { |raw| play_loop(raw, action, mission, path, duration) }
      end
    end

    private

    def play_loop(stdin, action, mission, path, duration)
      map = mission.build_map
      player = build_player(mission, path.first)
      terminals = mission.build_terminals
      actors = build_actors(action[:actors])
      fire_times = Array(action[:fire_times]).map(&:to_f)

      started_at = clock
      last_tick = started_at

      loop do
        now = clock
        elapsed = now - started_at
        dt = now - last_tick
        last_tick = now

        return if skip_requested?(stdin)

        pose = interpolate_pose(path, [elapsed, duration].min)
        player.x = pose[:x]
        player.y = pose[:y]
        player.angle = pose[:angle]
        player.game_time += dt
        player.fire_flash = fire_active?(fire_times, elapsed) ? 3 : 0

        @renderer.render(
          player: player,
          map: map,
          enemies: active_actors(actors, elapsed),
          projectiles: [],
          drops: [],
          terminals: terminals
        )
        render_caption(action[:caption], elapsed, duration)

        break if elapsed >= duration

        sleep(Config::FRAME_DT)
      end
    end

    def build_player(mission, pose)
      weapons = mission.build_weapons
      weapons = [Weapon::Base.build(:pistol)] if weapons.empty?
      player = Player.new(
        x: pose[:x],
        y: pose[:y],
        angle: pose[:angle] || 0.0,
        weapons: weapons
      )
      player.drops = []
      player
    end

    def build_actors(definitions)
      Array(definitions).map do |definition|
        {
          entity: DemoActor.new(
            x: definition[:x].to_f,
            y: definition[:y].to_f,
            sprite_id: definition[:sprite_id].to_sym,
            alive: true,
            hp: 1,
            max_hp: 1
          ),
          from: definition.fetch(:from, 0.0).to_f,
          to: definition.fetch(:to, Float::INFINITY).to_f
        }
      end
    end

    def active_actors(actors, elapsed)
      actors.filter_map do |actor|
        next unless elapsed >= actor[:from] && elapsed <= actor[:to]

        actor[:entity]
      end
    end

    def interpolate_pose(path, elapsed)
      current = path.first
      nxt = path.last

      path.each_cons(2) do |left, right|
        if elapsed <= right[:t].to_f
          current = left
          nxt = right
          break
        end
      end

      span = nxt[:t].to_f - current[:t].to_f
      ratio = span <= 0 ? 1.0 : ((elapsed - current[:t].to_f) / span).clamp(0.0, 1.0)

      {
        x: lerp(current[:x], nxt[:x], ratio),
        y: lerp(current[:y], nxt[:y], ratio),
        angle: lerp_angle(current[:angle] || 0.0, nxt[:angle] || 0.0, ratio)
      }
    end

    def render_caption(caption, elapsed, duration)
      return if caption.to_s.empty?

      rows, cols = @stdout.winsize
      lines = caption.to_s.split("\n")
      base_row = [rows - lines.size - 2, 2].max

      buf = +"\e[?2026h"
      lines.each_with_index do |line, index|
        col = [(cols - line.size) / 2 + 1, 1].max
        buf << "\e[#{base_row + index};1H\e[K"
        buf << "\e[#{base_row + index};#{col}H\e[1;97m#{line}\e[0m"
      end

      hint = "[Enter] Skip Demo"
      progress = "#{elapsed.ceil}/#{duration.ceil}s"
      buf << "\e[#{rows - 1};3H\e[90m#{hint}\e[0m"
      buf << "\e[#{rows - 1};#{[cols - progress.size - 1, 1].max}H\e[90m#{progress}\e[0m"
      buf << "\e[?2026l"
      TerminalOutput.write_all(@stdout, buf)
    end

    def fire_active?(fire_times, elapsed)
      fire_times.any? { |time| (elapsed - time).abs < 0.12 }
    end

    def skip_requested?(stdin)
      while IO.select([stdin], nil, nil, 0)
        data = stdin.read_nonblock(64)
        return true if data.bytes.any? { |byte| [13, 10, 27, 32, 81, 113].include?(byte) }
      end

      false
    rescue IO::WaitReadable
      false
    end

    def lerp(a, b, t)
      a.to_f + (b.to_f - a.to_f) * t
    end

    def lerp_angle(a, b, t)
      delta = b.to_f - a.to_f
      delta -= Math::PI * 2 while delta > Math::PI
      delta += Math::PI * 2 while delta < -Math::PI
      a.to_f + delta * t
    end

    def clock
      Process.clock_gettime(Process::CLOCK_MONOTONIC)
    end
  end
end
