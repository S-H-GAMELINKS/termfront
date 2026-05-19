# frozen_string_literal: true

module Termfront
  module Enemy
    class Executor < Base
      def damage    = 25
      def range     = 8.0
      def cooldown  = 2.5
      def speed     = 1.2
      def drop_type = :shock_rifle
      def drop_ammo = 100
      def sprite_id = :executor
      def base_hp   = 2
    end

    Base.register(:executor, Executor)
  end
end
