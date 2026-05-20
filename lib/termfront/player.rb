# frozen_string_literal: true

module Termfront
  class Player
    attr_accessor :x, :y, :angle, :shield, :health, :weapons, :weapon_idx,
                  :last_fire, :dead, :game_time, :last_damage, :damage_flash,
                  :fire_flash, :beep_count, :last_beep, :regen_active,
                  :swap_pressed, :pickup_pressed, :drops

    def initialize(x:, y:, angle:, weapons:)
      @x = x
      @y = y
      @angle = angle
      @weapons = weapons
      @weapon_idx = 0
      @last_fire = 0.0
      @shield = Config::SHIELD_MAX
      @health = Config::HEALTH_MAX
      @dead = false
      @game_time = 0.0
      @last_damage = -Config::SHIELD_DELAY
      @damage_flash = 0
      @fire_flash = 0
      @beep_count = 0
      @last_beep = 0.0
      @regen_active = false
      @swap_pressed = false
      @pickup_pressed = false
      @drops = []
    end

    def current_weapon
      @weapons[@weapon_idx]
    end

    def swap_weapon
      @weapon_idx = 1 - @weapon_idx
    end

    def apply_damage(amount)
      @last_damage = @game_time
      @damage_flash = 3

      if @shield > 0
        overflow = amount - @shield
        @shield = [(@shield - amount), 0].max
        @health = [@health - [overflow, 0].max, 0].max if @shield == 0
      else
        @health = [@health - amount, 0].max
      end

      @dead = true if @health <= 0
    end

    def update_shield(dt, stdout, audio: nil)
      regen_now = @shield < Config::SHIELD_MAX && (@game_time - @last_damage) >= Config::SHIELD_DELAY
      if regen_now
        unless @regen_active
          @regen_active = true
          if audio
            audio.play_loop_se(:shield_regen)
          else
            stdout.syswrite("\a")
          end
        end
        @shield = [@shield + Config::SHIELD_REGEN * dt, Config::SHIELD_MAX].min
      else
        audio&.stop_loop_se(:shield_regen) if @regen_active
        @regen_active = false
      end
      @damage_flash -= 1 if @damage_flash > 0

      if @shield >= Config::SHIELD_MAX && @health < Config::HEALTH_MAX
        @health = [@health + Config::SHIELD_REGEN * dt, Config::HEALTH_MAX].min
      end

      return unless @shield == 0 && @health > 0

      @beep_count = 3 if @beep_count <= 0
      now = Process.clock_gettime(Process::CLOCK_MONOTONIC)
      return unless (now - @last_beep) >= Config::BEEP_INTERVAL

      if audio
        audio.play_se(:shield_alarm)
      else
        stdout.syswrite("\a")
      end
      @last_beep = now
      @beep_count -= 1
    end

    def try_pickup
      nearest = nil
      best_d2 = Config::PICKUP_RADIUS**2
      @drops.each do |d|
        d2 = (d.x - @x)**2 + (d.y - @y)**2
        if d2 < best_d2
          nearest = d
          best_d2 = d2
        end
      end
      return unless nearest

      cur = current_weapon
      if cur.type_id == nearest.type
        max = cur.max_ammo
        cur.ammo = [cur.ammo + nearest.ammo, max].min if max
      else
        @drops << DropItem::Weapon.new(x: @x, y: @y, type: cur.type_id, ammo: cur.ammo)
        @weapons[@weapon_idx] = Weapon::Base.build(nearest.type, nearest.ammo)
      end
      @drops.delete(nearest)
    end

    def process_fire(enemies, map)
      dx = Math.cos(@angle)
      dy = Math.sin(@angle)

      weapon = current_weapon

      best = nil
      best_d = 1e30
      enemies.each do |e|
        next unless e.alive

        ex = e.x - @x
        ey = e.y - @y
        dot = ex * dx + ey * dy
        next if dot < 0.1

        perp = (ex * (-dy) + ey * dx).abs
        next if perp > weapon.hit_width

        if dot < best_d && map.line_of_sight?(@x, @y, e.x, e.y)
          best = e
          best_d = dot
        end
      end
      return unless best

      best.take_damage(1)
      return if best.alive

      @drops << DropItem::Weapon.new(x: best.x, y: best.y, type: best.drop_type, ammo: best.drop_ammo)
    end
  end
end
