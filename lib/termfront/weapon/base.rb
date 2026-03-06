# frozen_string_literal: true

module Termfront
  module Weapon
    class Base
      attr_accessor :ammo

      def initialize(ammo: nil)
        @ammo = ammo.nil? ? max_ammo : ammo
      end

      def name        = raise(NotImplementedError)
      def max_ammo    = raise(NotImplementedError)
      def cooldown    = raise(NotImplementedError)
      def hit_width   = raise(NotImplementedError)
      def type_id     = raise(NotImplementedError)

      def infinite_ammo? = max_ammo.nil?

      def can_fire?(last_fire, now)
        (now - last_fire) > cooldown
      end

      def consume_ammo!
        @ammo -= 1 if @ammo
      end

      class << self
        def registry
          @registry ||= {}
        end

        def register(type, klass)
          registry[type] = klass
        end

        def build(type, ammo = nil)
          klass = registry[type] || raise(ArgumentError, "Unknown weapon type: #{type}")
          ammo ? klass.new(ammo: ammo) : klass.new
        end
      end
    end
  end
end
