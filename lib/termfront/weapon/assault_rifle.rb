# frozen_string_literal: true

module Termfront
  module Weapon
    class AssaultRifle < Base
      def name      = "AR"
      def max_ammo  = 60
      def cooldown  = 0.12
      def hit_width = 0.3
      def type_id   = :ar
    end

    Base.register(:ar, AssaultRifle)
  end
end
