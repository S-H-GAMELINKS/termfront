# frozen_string_literal: true

module Termfront
  class Projectile
    attr_accessor :x, :y, :vx, :vy, :type

    def initialize(x:, y:, vx:, vy:, type:)
      @x = x
      @y = y
      @vx = vx
      @vy = vy
      @type = type
    end

    def update(dt)
      @x += @vx * dt
      @y += @vy * dt
    end

    def hit_wall?(map)
      map.wall_at?(@x, @y)
    end

    def hit_player?(px, py, radius = Config::PROJ_RADIUS)
      (@x - px).abs < radius && (@y - py).abs < radius
    end

    def self.update_all(projectiles, map, player)
      projectiles.reject! do |p|
        p.update(0) # dt is applied in the caller
        if p.hit_wall?(map)
          true
        elsif p.hit_player?(player.x, player.y)
          enemy_klass = Enemy::Base.registry[p.type]
          dmg = enemy_klass ? enemy_klass.allocate.send(:damage) : 10
          player.apply_damage(dmg)
          true
        else
          false
        end
      end
    end
  end
end
