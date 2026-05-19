# frozen_string_literal: true

require "json"

module Termfront
  module Mission
    module EventLoader
      module_function

      def load_file(path)
        return [] unless File.file?(path)

        doc = JSON.parse(File.read(path))
        events = doc.fetch("events") do
          raise ArgumentError, "event file #{path} is missing top-level events array"
        end

        unless events.is_a?(Array)
          raise ArgumentError, "event file #{path} must define events as an array"
        end

        events.map.with_index do |event, index|
          validate_event!(event, path, index)
        end
      end

      def validate_event!(event, path, index)
        unless event.is_a?(Hash)
          raise ArgumentError, "event #{index} in #{path} must be an object"
        end

        id = event["id"]
        trigger = event["trigger"]
        actions = event["actions"]

        raise ArgumentError, "event #{index} in #{path} is missing id" if blank?(id)
        raise ArgumentError, "event #{id} in #{path} is missing trigger" unless trigger.is_a?(Hash)
        raise ArgumentError, "event #{id} in #{path} is missing actions" unless actions.is_a?(Array) && !actions.empty?

        trigger_type = trigger["type"]
        raise ArgumentError, "event #{id} in #{path} trigger is missing type" if blank?(trigger_type)

        normalized_actions = actions.map.with_index do |action, action_index|
          validate_action!(action, path, id, action_index)
        end

        normalized_trigger = symbolize_keys(trigger).merge(type: trigger_type.to_sym)
        normalized_trigger[:terminal_id] = normalized_trigger[:terminal_id].to_sym if normalized_trigger[:terminal_id].is_a?(String)

        {
          id: id,
          once: event.fetch("once", true),
          trigger: normalized_trigger,
          actions: normalized_actions
        }
      end

      def validate_action!(action, path, event_id, index)
        unless action.is_a?(Hash)
          raise ArgumentError, "action #{index} in event #{event_id} (#{path}) must be an object"
        end

        type = action["type"]
        raise ArgumentError, "action #{index} in event #{event_id} (#{path}) is missing type" if blank?(type)

        symbolize_keys(action).merge(type: type.to_sym)
      end

      def symbolize_keys(value)
        case value
        when Array
          value.map { |item| symbolize_keys(item) }
        when Hash
          value.each_with_object({}) do |(key, item), memo|
            memo[key.to_sym] = symbolize_keys(item)
          end
        else
          value
        end
      end

      def blank?(value)
        value.nil? || value == ""
      end
    end
  end
end
