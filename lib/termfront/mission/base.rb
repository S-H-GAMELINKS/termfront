# frozen_string_literal: true

module Termfront
  module Mission
    class Base
      def id
        self.class.name.split("::").last
          .gsub(/([a-z0-9])([A-Z])/, '\1_\2')
          .downcase
      end

      def name      = raise(NotImplementedError)
      def briefing  = raise(NotImplementedError)
      def map_data  = raise(NotImplementedError)
      def spawn     = raise(NotImplementedError)
      def weapon_defs = raise(NotImplementedError)
      def enemy_defs  = raise(NotImplementedError)

      def events_path
        File.expand_path("../../../data/events/#{id}.json", __dir__)
      end

      def event_definitions
        @event_definitions ||= EventLoader.load_file(events_path)
      end

      def build_terminals
        terminal_ids = event_definitions.filter_map do |event|
          trigger = event[:trigger]
          trigger[:terminal_id] if trigger[:type] == :terminal_used
        end.uniq

        map_data.each_with_index.filter_map do |row, y|
          row.chars.each_with_index.filter_map do |cell, x|
            next unless cell == "*"

            { id: (terminal_ids.shift || :"terminal_#{x}_#{y}"), x: x + 0.5, y: y + 0.5 }
          end
        end.flatten
      end

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

        def wavesfight
          @wavesfight ||= []
        end

        def register(klass)
          campaign << klass
        end

        def register_wavesfight(klass)
          wavesfight << klass
        end
      end
    end
  end
end
