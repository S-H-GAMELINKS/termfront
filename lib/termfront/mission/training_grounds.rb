# frozen_string_literal: true

module Termfront
  module Mission
    class TrainingGrounds < Base
      def name = "Training Grounds"
      def briefing = "Clear a small compound. Learn the basics."

      def map_data
        [
          "################",
          "#..............#",
          "#..............#",
          "#......##......#",
          "#......##......#",
          "#..............#",
          "#..............#",
          "#..............#",
          "#..............#",
          "################"
        ]
      end

      def spawn = [2.5, 5.0, 0.0]
      def weapon_defs = [[:pistol, nil]]

      def enemy_defs
        [
          [10.5, 3.5, 10.5, 6.5, :crawler],
          [13.5, 7.5, 13.5, 2.5, :crawler]
        ]
      end
    end

    Base.register(TrainingGrounds)
  end
end
