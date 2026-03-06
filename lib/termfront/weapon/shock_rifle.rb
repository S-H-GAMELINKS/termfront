# frozen_string_literal: true

module Termfront
  module Weapon
    class ShockRifle < Base
      def name      = "S.Rifle"
      def max_ammo  = 100
      def cooldown  = 0.15
      def hit_width = 0.5
      def type_id   = :shock_rifle
    end

    Base.register(:shock_rifle, ShockRifle)
  end
end
