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
    assert_equal Termfront::Config::PVP_HIT_DMG, payload[:d]
  end

  def test_pvp_server_ignores_client_supplied_damage
    server = Termfront::Network::Server.new
    enemy_socket = FakeSocket.new([])

    roster = [
      { id: 0, team: 0, alive: true, socket: FakeSocket.new([]) },
      { id: 1, team: 1, alive: true, socket: enemy_socket }
    ]

    server.send(:route_hit, roster, roster[0], { target: 1, d: 999_999 })
    payload = JSON.parse(enemy_socket.writes.first, symbolize_names: true)
    assert_equal Termfront::Config::PVP_HIT_DMG, payload[:d],
                 "server must not relay attacker-controlled damage values"
  end

  FakeEnemy = Struct.new(:alive, :x, :y) do
    def update(*); end
  end

  def wavesfight_test_session(clock)
    {
      clock: clock,
      enemies: [FakeEnemy.new(true, 0.0, 0.0)],
      projectiles: [],
      map: nil,
      mission: nil,
      difficulty: 0,
      wave: 1
    }
  end

  def wavesfight_test_player(shield:, last_damage:)
    {
      id: 0, alive: true, fire_flash: 0,
      x: 5.0, y: 5.0,
      shield: shield,
      health: Termfront::Config::HEALTH_MAX.to_f,
      last_damage: last_damage
    }
  end

  def test_wavesfight_server_regenerates_player_shield_after_delay
    server = Termfront::Network::Server.new
    clock = 100.0
    roster = [wavesfight_test_player(shield: 50.0,
                                     last_damage: clock - Termfront::Config::SHIELD_DELAY - 1.0)]
    session = wavesfight_test_session(clock)

    dt = 0.1
    server.send(:update_wavesfight_session, roster, session, dt)

    expected = 50.0 + Termfront::Config::SHIELD_REGEN * dt
    assert_in_delta expected, roster[0][:shield], 0.0001,
                    "shield must regenerate when SHIELD_DELAY has elapsed"
  end

  def test_wavesfight_server_does_not_regenerate_within_shield_delay
    server = Termfront::Network::Server.new
    clock = 100.0
    roster = [wavesfight_test_player(shield: 50.0, last_damage: clock - 0.1)]
    session = wavesfight_test_session(clock)

    server.send(:update_wavesfight_session, roster, session, 0.1)

    assert_equal 50.0, roster[0][:shield],
                 "shield must stay flat while still within SHIELD_DELAY of last damage"
  end

  def test_wavesfight_server_apply_damage_resets_last_damage
    server = Termfront::Network::Server.new
    player = {
      shield: Termfront::Config::SHIELD_MAX.to_f,
      health: Termfront::Config::HEALTH_MAX.to_f,
      last_damage: -Termfront::Config::SHIELD_DELAY,
      alive: true
    }

    server.send(:apply_wavesfight_damage, player, 10, 42.0)

    assert_equal 42.0, player[:last_damage]
    assert_equal Termfront::Config::SHIELD_MAX - 10, player[:shield]
  end

  def test_audio_manager_rejects_paths_outside_data_audio
    manager = Termfront::AudioManager.new
    manager.instance_variable_set(:@manifest, {
                                    "bgm" => { "evil" => "../../../etc/passwd" },
                                    "se" => { "absolute" => "/etc/passwd" }
                                  })

    assert_nil manager.send(:asset_path, :bgm, :evil),
               "manifest must not resolve relative paths that escape the audio directory"
    assert_nil manager.send(:asset_path, :se, :absolute),
               "manifest must not resolve absolute paths outside data/audio"
  end

  def test_audio_manager_accepts_valid_data_audio_path
    manager = Termfront::AudioManager.new
    manager.instance_variable_set(:@manifest, {
                                    "bgm" => { "title" => "data/audio/title.mp3" }
                                  })
    path = manager.send(:asset_path, :bgm, :title)
    refute_nil path
    assert path.end_with?("data/audio/title.mp3")
  end

  CloseableSocket = Struct.new(:closed) do
    def close
      self.closed = true
    end
  end

  def test_enqueue_pvp_player_rejects_when_queue_full
    server = Termfront::Network::Server.new
    full = Array.new(Termfront::Network::Server::MAX_QUEUE_PER_MODE) { { socket: CloseableSocket.new(false) } }
    server.instance_variable_get(:@queues)[1] = full

    new_socket = CloseableSocket.new(false)
    server.send(:enqueue_pvp_player, new_socket, 1)

    assert_equal true, new_socket.closed,
                 "incoming client must be closed when the queue is at MAX_QUEUE_PER_MODE"
    assert_equal Termfront::Network::Server::MAX_QUEUE_PER_MODE,
                 server.instance_variable_get(:@queues)[1].size,
                 "queue must not grow beyond MAX_QUEUE_PER_MODE"
  end

  def test_enqueue_wavesfight_player_rejects_when_queue_full
    server = Termfront::Network::Server.new
    mission_id = Termfront::Mission::Base.wavesfight.first.new.id
    key = [mission_id, 0]
    full = Array.new(Termfront::Network::Server::MAX_QUEUE_PER_MODE) { { socket: CloseableSocket.new(false) } }
    server.instance_variable_get(:@wavesfight_queues)[key] = full

    new_socket = CloseableSocket.new(false)
    server.send(:enqueue_wavesfight_player, new_socket, { mode: :wavesfight, mission_id: mission_id, difficulty: 0 })

    assert_equal true, new_socket.closed
    assert_equal Termfront::Network::Server::MAX_QUEUE_PER_MODE,
                 server.instance_variable_get(:@wavesfight_queues)[key].size
  end

  def test_wavesfight_client_safe_weapon_whitelist
    client = Termfront::Network::WavesfightClient.allocate
    assert_equal :ar, client.send(:safe_weapon, "ar")
    assert_equal :pistol, client.send(:safe_weapon, :pistol)
    assert_nil client.send(:safe_weapon, "shock_rifle")
    assert_nil client.send(:safe_weapon, "bogus")
    assert_nil client.send(:safe_weapon, nil)
  end

  def test_wavesfight_client_safe_enemy_type_whitelist
    client = Termfront::Network::WavesfightClient.allocate
    assert_equal :crawler, client.send(:safe_enemy_type, "crawler")
    assert_equal :executor, client.send(:safe_enemy_type, "executor")
    assert_nil client.send(:safe_enemy_type, "boss")
    assert_nil client.send(:safe_enemy_type, "")
    assert_nil client.send(:safe_enemy_type, 42)
  end

  def test_pvp_client_safe_weapon_whitelist
    client = Termfront::Network::Client.allocate
    assert_equal :ar, client.send(:safe_weapon, "ar")
    assert_equal :pistol, client.send(:safe_weapon, :pistol)
    assert_nil client.send(:safe_weapon, "shock_rifle")
    assert_nil client.send(:safe_weapon, nil)
  end

  def test_valid_position_accepts_finite_in_bounds
    server = Termfront::Network::Server.new
    map = Termfront::Map.new(["####", "#..#", "####"])

    assert server.send(:valid_position?, { x: 1.5, y: 1.5, a: 0.0 }, map)
    assert server.send(:valid_position?, { x: 1, y: 1, a: 0 }, map)
  end

  def test_valid_position_rejects_non_finite_and_out_of_bounds
    server = Termfront::Network::Server.new
    map = Termfront::Map.new(["####", "#..#", "####"])

    refute server.send(:valid_position?, { x: Float::NAN, y: 1.5, a: 0.0 }, map)
    refute server.send(:valid_position?, { x: 1.5, y: Float::INFINITY, a: 0.0 }, map)
    refute server.send(:valid_position?, { x: -1.0, y: 1.5, a: 0.0 }, map)
    refute server.send(:valid_position?, { x: 100.0, y: 1.5, a: 0.0 }, map)
    refute server.send(:valid_position?, { x: "1.5", y: 1.5, a: 0.0 }, map)
    refute server.send(:valid_position?, { x: nil, y: 1.5, a: 0.0 }, map)
  end

  def test_validate_int_enforces_range_and_type
    server = Termfront::Network::Server.new

    assert_equal 0, server.send(:validate_int, 0, min: 0, max: 10)
    assert_equal 10, server.send(:validate_int, 10, min: 0, max: 10)
    assert_equal 5, server.send(:validate_int, 5.7, min: 0, max: 10)
    assert_nil server.send(:validate_int, -1, min: 0, max: 10)
    assert_nil server.send(:validate_int, 11, min: 0, max: 10)
    assert_nil server.send(:validate_int, "5", min: 0, max: 10)
    assert_nil server.send(:validate_int, nil, min: 0, max: 10)
    assert_nil server.send(:validate_int, Float::NAN, min: 0, max: 10)
  end

  def test_normalize_weapon_accepts_whitelisted_names
    server = Termfront::Network::Server.new
    assert_equal :pistol, server.send(:normalize_weapon, "pistol")
    assert_equal :ar, server.send(:normalize_weapon, "ar")
    assert_equal :ar, server.send(:normalize_weapon, :ar)
  end

  def test_normalize_weapon_rejects_other_values
    server = Termfront::Network::Server.new
    assert_nil server.send(:normalize_weapon, "shock_rifle")
    assert_nil server.send(:normalize_weapon, "bogus")
    assert_nil server.send(:normalize_weapon, nil)
    assert_nil server.send(:normalize_weapon, 42)
    assert_nil server.send(:normalize_weapon, "")
  end

  def test_match_timeout_reason_signals_ttl_after_max_duration
    server = Termfront::Network::Server.new
    now = 1000.0
    started = now - Termfront::Network::Server::MATCH_MAX_DURATION - 1

    assert_equal "match_ttl", server.send(:match_timeout_reason, now, started, now)
  end

  def test_match_timeout_reason_signals_idle_after_idle_timeout
    server = Termfront::Network::Server.new
    now = 1000.0
    started = now - 10
    stale = now - Termfront::Network::Server::MATCH_IDLE_TIMEOUT - 1

    assert_equal "idle", server.send(:match_timeout_reason, now, started, stale)
  end

  def test_match_timeout_reason_returns_nil_during_active_match
    server = Termfront::Network::Server.new
    now = 1000.0

    assert_nil server.send(:match_timeout_reason, now, now - 5, now - 1)
  end

  def test_supervise_match_catches_exception_and_closes_sockets
    server = Termfront::Network::Server.new
    sock = CloseableSocket.new(false)
    server.send(:supervise_match, [{ socket: sock }]) { raise "boom" }

    assert_equal true, sock.closed,
                 "supervise_match must close sockets even when the body raises"
  end

  def test_supervise_match_closes_sockets_on_normal_exit
    server = Termfront::Network::Server.new
    sock = CloseableSocket.new(false)
    server.send(:supervise_match, [{ socket: sock }]) { :ok }

    assert_equal true, sock.closed,
                 "supervise_match must always close sockets via ensure"
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
