# frozen_string_literal: true

module Termfront
  module Mission
    class Base
      def name      = raise(NotImplementedError)
      def briefing  = raise(NotImplementedError)
      def map_data  = raise(NotImplementedError)
      def spawn     = raise(NotImplementedError)
      def weapon_defs = raise(NotImplementedError)
      def enemy_defs  = raise(NotImplementedError)

      def build_map
        Map.new(map_data)
      end

      def build_weapons
        weapon_defs.map { |type, ammo| Weapon::Base.build(type, ammo) }
      end

      def build_enemies(difficulty_index)
        enemies = enemy_defs.map do |ed|
          type = ed[4]
          Enemy::Base.build(type, ed, difficulty_index)
        end
        if difficulty_index
          extra = Enemy::Base::DIFFICULTIES[difficulty_index][:extra_enemies]
          enemies += Enemy::Base.generate_extras(enemy_defs, extra, difficulty_index)
        end
        enemies
      end

      class << self
        def campaign
          @campaign ||= []
        end

        def register(klass)
          campaign << klass
        end
      end
    end
  end
end
