# frozen_string_literal: true

module Termfront
  module Enemy
    class Crawler < Base
      def damage    = 10
      def range     = 5.0
      def cooldown  = 1.5
      def speed     = 1.8
      def drop_type = :shock_pistol
      def drop_ammo = 60
      def sprite_id = :crawler
      def base_hp   = 1
    end

    Base.register(:crawler, Crawler)
  end
end
