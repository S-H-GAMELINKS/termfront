# frozen_string_literal: true

module Termfront
  module DropItem
    class Base
      attr_accessor :x, :y

      def initialize(x:, y:)
        @x = x
        @y = y
      end

      def in_range?(px, py)
        (px - @x)**2 + (py - @y)**2 < Config::PICKUP_RADIUS**2
      end

      def pickup!(player)
        raise NotImplementedError
      end

      def sprite_color
        raise NotImplementedError
      end
    end
  end
end
