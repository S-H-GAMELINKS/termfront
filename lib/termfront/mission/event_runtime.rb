# frozen_string_literal: true

require "set"

module Termfront
  module Mission
    class EventRuntime
      def initialize(events)
        @events = events
        @fired = Set.new
      end

      def trigger(type, payload = {})
        normalized_type = type.to_sym
        normalized_payload = payload.transform_keys(&:to_sym)

        @events.filter_map do |event|
          next if event[:once] && @fired.include?(event[:id])
          next unless matches?(event[:trigger], normalized_type, normalized_payload)

          @fired << event[:id] if event[:once]
          event
        end
      end

      private

      def matches?(trigger, type, payload)
        return false unless trigger[:type] == type

        trigger.all? do |key, value|
          key == :type || payload[key] == value
        end
      end
    end
  end
end
