# frozen_string_literal: true

module Termfront
  module Mission
    class FinalPush < Base
      def name = "Final Push"
      def briefing = "Storm the fortress. Maximum resistance. Good luck."

      def map_data
        [
          "##########################",
          "#............#...........#",
          "#............#...........#",
          "#............#...........#",
          "#...........*............#",
          "#............#...........#",
          "#............#..####..####",
          "####..########..#........#",
          "#...............#........#",
          "#...........*...#........#",
          "#...............#........#",
          "##########################"
        ]
      end

      def spawn = [2.5, 2.5, 0.0]
      def weapon_defs = [[:ar, 60], [:pistol, nil]]

      def enemy_defs
        [
          [8.5,  2.5, 8.5,  5.5, :executor],
          [4.5,  9.5, 4.5,  8.5, :crawler],
          [10.5, 9.5, 10.5, 8.5, :crawler],
          [18.5, 2.5, 18.5, 5.5, :executor],
          [22.5, 8.5, 22.5, 10.5, :executor],
          [16.5, 9.5, 16.5, 8.5, :crawler]
        ]
      end
    end

    Base.register(FinalPush)
    Base.register_wavesfight(FinalPush)
  end
end
