# frozen_string_literal: true

require "test_helper"

class TestTermfront < Minitest::Test
  def test_that_it_has_a_version_number
    refute_nil ::Termfront::VERSION
  end

  def test_campaign_missions_load_external_events
    Termfront::Mission::Base.campaign.each do |mission_klass|
      mission = mission_klass.new
      events = mission.event_definitions

      refute_empty events, "#{mission.id} should load at least one event"
      assert events.all? { |event| event[:trigger].is_a?(Hash) }
      assert events.all? { |event| event[:actions].is_a?(Array) && !event[:actions].empty? }
    end
  end

  def test_event_loader_returns_empty_for_missing_files
    path = "/tmp/termfront-missing-events.json"
    assert_equal [], Termfront::Mission::EventLoader.load_file(path)
  end

  def test_event_loader_symbolizes_trigger_and_actions
    path = "/tmp/termfront-sample-events.json"
    File.write(path, <<~JSON)
      {
        "events": [
          {
            "id": "sample",
            "trigger": { "type": "mission_start" },
            "actions": [
              { "type": "dialogue", "speaker": "OPS", "text": "Ready." }
            ]
          }
        ]
      }
    JSON

    events = Termfront::Mission::EventLoader.load_file(path)
    assert_equal :mission_start, events.first[:trigger][:type]
    assert_equal :dialogue, events.first[:actions].first[:type]
  ensure
    File.delete(path) if path && File.exist?(path)
  end

  def test_mission_build_terminals_uses_event_terminal_ids
    mission = Termfront::Mission::TheGauntlet.new
    terminals = mission.build_terminals

    refute_empty terminals
    assert_equal :service_hub, terminals.first[:id]
  end

  def test_event_runtime_matches_trigger_payload_once
    events = [
      {
        id: "terminal_a",
        once: true,
        trigger: { type: :terminal_used, terminal_id: :alpha },
        actions: [{ type: :text, text: "Hello" }]
      }
    ]

    runtime = Termfront::Mission::EventRuntime.new(events)
    assert_equal 1, runtime.trigger(:terminal_used, terminal_id: :alpha).size
    assert_empty runtime.trigger(:terminal_used, terminal_id: :alpha)
    assert_empty runtime.trigger(:terminal_used, terminal_id: :beta)
  end
end
