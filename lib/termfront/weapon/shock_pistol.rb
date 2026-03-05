# frozen_string_literal: true

module Termfront
  module Weapon
    class ShockPistol < Base
      def name      = "S.Pistol"
      def max_ammo  = 60
      def cooldown  = 0.35
      def hit_width = 0.6
      def type_id   = :shock_pistol
    end

    Base.register(:shock_pistol, ShockPistol)
  end
end
