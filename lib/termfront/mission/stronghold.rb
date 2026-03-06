# frozen_string_literal: true

module Termfront
  module Mission
    class Stronghold < Base
      def name = "Stronghold"
      def briefing = "Multi-room stronghold. Executors guard the inner rooms."

      def map_data
        [
          "####################",
          "#........#.........#",
          "#........#.........#",
          "#........#.........#",
          "#...........*......#",
          "#........#.........#",
          "#........#.........#",
          "####..####.........#",
          "#........#.........#",
          "#........#.........#",
          "#................*.#",
          "#........#.........#",
          "#........#.........#",
          "####################"
        ]
      end

      def spawn = [2.5, 2.5, 0.0]
      def weapon_defs = [[:ar, 60], [:pistol, nil]]

      def enemy_defs
        [
          [5.5,  5.5, 5.5,  2.5, :crawler],
          [14.5, 2.5, 14.5, 5.5, :executor],
          [3.5, 10.5, 3.5, 12.5, :crawler],
          [14.5, 9.5, 14.5, 12.5, :executor],
          [10.5, 11.5, 15.5, 11.5, :crawler]
        ]
      end
    end

    Base.register(Stronghold)
  end
end
