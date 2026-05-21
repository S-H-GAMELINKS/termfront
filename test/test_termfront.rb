# frozen_string_literal: true

require "test_helper"
require "stringio"

class TestTermfront < Minitest::Test
  FakeSocket = Struct.new(:writes) do
    def write(data)
      writes << data
    end
  end

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

  def test_wavesfight_missions_are_registered
    wavesfight = Termfront::Mission::Base.wavesfight

    assert_includes wavesfight, Termfront::Mission::CorridorSweep
    assert_includes wavesfight, Termfront::Mission::Stronghold
    assert_includes wavesfight, Termfront::Mission::FinalPush
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

  def test_player_starts_and_stops_shield_regen_loop
    player = Termfront::Player.new(
      x: 1.5, y: 1.5, angle: 0.0,
      weapons: [Termfront::Weapon::Base.build(:pistol), Termfront::Weapon::Base.build(:pistol)]
    )
    player.shield = 50.0
    player.game_time = Termfront::Config::SHIELD_DELAY

    audio = Class.new do
      attr_reader :events

      def initialize
        @events = []
      end

      def play_loop_se(name)
        @events << [:play, name]
      end

      def stop_loop_se(name = nil)
        @events << [:stop, name]
      end
    end.new

    player.update_shield(0.1, StringIO.new, audio: audio)
    player.shield = Termfront::Config::SHIELD_MAX
    player.update_shield(0.1, StringIO.new, audio: audio)

    assert_equal [[:play, :shield_regen], [:stop, :shield_regen]], audio.events
  end

  def test_pvp_server_detects_winning_team
    server = Termfront::Network::Server.new
    roster = [
      { team: 0, alive: true },
      { team: 0, alive: true },
      { team: 1, alive: false },
      { team: 1, alive: false }
    ]

    assert_equal 0, server.send(:winning_team, roster)

    roster[2][:alive] = true
    assert_nil server.send(:winning_team, roster)
  end

  def test_pvp_server_routes_hits_only_to_enemy_targets
    server = Termfront::Network::Server.new
    ally_socket = FakeSocket.new([])
    enemy_socket = FakeSocket.new([])

    roster = [
      { id: 0, team: 0, alive: true, socket: FakeSocket.new([]) },
      { id: 1, team: 0, alive: true, socket: ally_socket },
      { id: 2, team: 1, alive: true, socket: enemy_socket }
    ]

    server.send(:route_hit, roster, roster[0], { target: 1, d: 25 })
    assert_empty ally_socket.writes

    server.send(:route_hit, roster, roster[0], { target: 2, d: 25 })
    refute_empty enemy_socket.writes
    payload = JSON.parse(enemy_socket.writes.first, symbolize_names: true)
    assert_equal :hit, payload[:t].to_sym
    assert_equal 0, payload[:from]
    assert_equal 25, payload[:d]
  end

  def test_pvp_server_spawns_are_walkable
    server = Termfront::Network::Server.new
    map = Termfront::Map.new(Termfront::Network::Server::PVP_MAP)

    server.send(:pvp_spawns).each do |spawn|
      x, y, = spawn
      assert_equal false, map.blocked?(x, y), "spawn #{spawn.inspect} should be walkable"
    end
  end
end
