# frozen_string_literal: true

module Termfront
  module Weapon
    class Pistol < Base
      def name      = "Pistol"
      def max_ammo  = nil
      def cooldown  = 0.45
      def hit_width = 0.5
      def type_id   = :pistol
    end

    Base.register(:pistol, Pistol)
  end
end
