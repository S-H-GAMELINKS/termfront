# frozen_string_literal: true

module Termfront
  module Mission
    class TheGauntlet < Base
      def name = "The Gauntlet"
      def briefing = "A long corridor with enemies in every room."

      def map_data
        [
          "##############################",
          "#.....#.....#.....#.....#....#",
          "#.....#.....#.....#.....#....#",
          "#...........*...........*....#",
          "#.....#.....#.....#.....#....#",
          "#.....#.....#.....#.....#....#",
          "#.....#.....#.....#.....#....#",
          "##############################"
        ]
      end

      def spawn = [2.5, 3.5, 0.0]
      def weapon_defs = [[:ar, 60], [:pistol, nil]]

      def enemy_defs
        [
          [4.5,  2.5, 4.5,  5.5, :crawler],
          [8.5,  5.5, 8.5,  2.5, :crawler],
          [14.5, 2.5, 14.5, 5.5, :crawler],
          [20.5, 5.5, 20.5, 2.5, :crawler],
          [26.5, 2.5, 26.5, 5.5, :crawler]
        ]
      end
    end

    Base.register(TheGauntlet)
  end
end
