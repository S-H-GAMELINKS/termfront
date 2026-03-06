# frozen_string_literal: true

module Termfront
  module Enemy
    class Base
      attr_accessor :x, :y, :wp_a, :wp_b, :wp_t, :wp_dir, :last_fire, :alive, :hp, :max_hp

      DIFFICULTIES = [
        { name: "Easy",      hp_mult: 1, cooldown_mult: 1.5, extra_enemies: 0 },
        { name: "Normal",    hp_mult: 2, cooldown_mult: 1.0, extra_enemies: 1 },
        { name: "Hard",      hp_mult: 3, cooldown_mult: 0.7, extra_enemies: 3 },
        { name: "Very Hard", hp_mult: 4, cooldown_mult: 0.5, extra_enemies: 5 }
      ].freeze

      def initialize(x:, y:, wp_a:, wp_b:, hp:)
        @x = x
        @y = y
        @wp_a = wp_a
        @wp_b = wp_b
        @wp_t = 0.0
        @wp_dir = 1
        @last_fire = 0.0
        @alive = true
        @hp = hp
        @max_hp = hp
      end

      def damage    = raise(NotImplementedError)
      def range     = raise(NotImplementedError)
      def cooldown  = raise(NotImplementedError)
      def speed     = raise(NotImplementedError)
      def drop_type = raise(NotImplementedError)
      def drop_ammo = raise(NotImplementedError)
      def sprite_id = raise(NotImplementedError)
      def base_hp   = raise(NotImplementedError)

      def dead? = !@alive

      def take_damage(amount)
        @hp -= amount
        return unless @hp <= 0

        @alive = false
      end

      def update(dt, player, projectiles, map, game_time, difficulty:)
        return unless @alive

        patrol(dt)

        edx = player.x - @x
        edy = player.y - @y
        edist = Math.sqrt(edx * edx + edy * edy)
        cd = cooldown
        cd *= DIFFICULTIES[difficulty][:cooldown_mult] if difficulty
        return unless edist < range && (game_time - @last_fire) > cd
        return unless map.line_of_sight?(@x, @y, player.x, player.y)

        @last_fire = game_time
        ndx = edx / edist
        ndy = edy / edist
        projectiles << Projectile.new(
          x: @x, y: @y,
          vx: ndx * Config::PROJ_SPEED,
          vy: ndy * Config::PROJ_SPEED,
          type: sprite_id
        )
      end

      def patrol(dt)
        seg_len = Math.sqrt(
          (@wp_b[0] - @wp_a[0])**2 + (@wp_b[1] - @wp_a[1])**2 + 0.01
        )
        @wp_t += @wp_dir * speed * dt / seg_len
        if @wp_t >= 1.0
          @wp_t = 1.0
          @wp_dir = -1
        elsif @wp_t <= 0.0
          @wp_t = 0.0
          @wp_dir = 1
        end
        @x = @wp_a[0] + (@wp_b[0] - @wp_a[0]) * @wp_t
        @y = @wp_a[1] + (@wp_b[1] - @wp_a[1]) * @wp_t
      end

      class << self
        def registry
          @registry ||= {}
        end

        def register(type, klass)
          registry[type] = klass
        end

        def build(type, enemy_def, difficulty_index)
          klass = registry[type] || raise(ArgumentError, "Unknown enemy type: #{type}")
          sx, sy, ax, ay, _type = enemy_def
          hp = compute_hp(klass, difficulty_index)
          klass.new(x: sx, y: sy, wp_a: [sx, sy], wp_b: [ax, ay], hp: hp)
        end

        def generate_extras(base_list, count, difficulty_index)
          return [] if count == 0 || base_list.empty?

          extras = []
          count.times do |i|
            src = base_list[i % base_list.size]
            sx, sy, ax, ay, type = src
            offset = 0.3 + (i * 0.2)
            klass = registry[type] || raise(ArgumentError, "Unknown enemy type: #{type}")
            hp = compute_hp(klass, difficulty_index)
            extras << klass.new(
              x: sx + offset, y: sy + offset,
              wp_a: [sx + offset, sy + offset],
              wp_b: [ax + offset, ay + offset],
              hp: hp
            )
          end
          extras
        end

        private

        def compute_hp(klass, difficulty_index)
          return 1 unless difficulty_index

          instance = klass.allocate
          instance.send(:base_hp) * DIFFICULTIES[difficulty_index][:hp_mult]
        end
      end
    end
  end
end
