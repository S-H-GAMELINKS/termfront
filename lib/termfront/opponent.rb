# frozen_string_literal: true

module Termfront
  class Opponent
    attr_accessor :x, :y, :angle, :shield, :health, :weapon, :ammo, :fire_flash

    def initialize(x:, y:, angle:, shield: Config::SHIELD_MAX, health: Config::HEALTH_MAX, weapon: :ar, ammo: 60,
                   fire_flash: 0)
      @x = x
      @y = y
      @angle = angle
      @shield = shield
      @health = health
      @weapon = weapon
      @ammo = ammo
      @fire_flash = fire_flash
    end

    def dup_state
      Opponent.new(x: @x, y: @y, angle: @angle, shield: @shield, health: @health,
                   weapon: @weapon, ammo: @ammo, fire_flash: @fire_flash)
    end
  end
end
