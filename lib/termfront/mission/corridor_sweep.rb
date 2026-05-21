# frozen_string_literal: true

module Termfront
  module Mission
    class CorridorSweep < Base
      def name = "Corridor Sweep"
      def briefing = "Sweep the original facility. Expect resistance."

      def map_data
        [
          "########################",
          "#..........#...........#",
          "#..........#...........#",
          "#..........#...........#",
          "#..........#...........#",
          "#......................#",
          "#..........####........#",
          "#......................#",
          "#..............#.......#",
          "#..............#.......#",
          "########################"
        ]
      end

      def spawn = [10.0, 6.0, 0.0]
      def weapon_defs = [[:ar, 60], [:pistol, nil]]

      def enemy_defs
        [
          [16.5, 1.5, 16.5, 4.5, :executor],
          [5.5,  8.5, 9.5,  8.5, :crawler],
          [20.5, 5.5, 20.5, 9.5, :crawler],
          [3.5,  2.5, 3.5,  4.5, :crawler]
        ]
      end
    end

    Base.register(CorridorSweep)
    Base.register_wavesfight(CorridorSweep)
  end
end
