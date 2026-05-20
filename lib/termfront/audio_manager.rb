# frozen_string_literal: true

require "json"
require "shellwords"
require "thread"

module Termfront
  class AudioManager
    Player = Struct.new(:command, :supports_loop, keyword_init: true)

    def initialize
      @manifest = load_manifest
      @bgm_player = detect_player(%w[ffplay afplay paplay aplay], prefer_loop: true)
      @loop_se_player = detect_player(%w[ffplay afplay paplay aplay], prefer_loop: true)
      @se_player = detect_player(%w[paplay afplay aplay ffplay], prefer_loop: false)
      @mutex = Mutex.new
      @bgm_pid = nil
      @bgm_thread = nil
      @bgm_stop = false
      @loop_se_pid = nil
      @loop_se_thread = nil
      @loop_se_stop = false
      @loop_se_name = nil
    end

    def play_bgm(name)
      path = asset_path(:bgm, name)
      return unless path

      stop_bgm

      @mutex.synchronize do
        @bgm_stop = false
        @bgm_thread = Thread.new do
          if @bgm_player&.supports_loop
            @bgm_pid = spawn_player(@bgm_player, path, loop_playback: true)
            wait_for_channel(:bgm)
          else
            loop do
              break if channel_stopped?(:bgm)

              @bgm_pid = spawn_player(@bgm_player, path, loop_playback: false)
              wait_for_channel(:bgm)
              break if channel_stopped?(:bgm)
            end
          end
        rescue StandardError
          nil
        ensure
          @mutex.synchronize do
            @bgm_pid = nil
            @bgm_thread = nil
          end
        end
      end
    end

    def stop_bgm
      thread = nil
      pid = nil

      @mutex.synchronize do
        @bgm_stop = true
        thread = @bgm_thread
        pid = @bgm_pid
      end

      terminate_process(pid) if pid
      thread&.join(0.5)
    end

    def play_se(name)
      path = asset_path(:se, name)
      return unless path && @se_player

      spawn_player(@se_player, path, loop_playback: false, detach: true)
    rescue StandardError
      nil
    end

    def play_loop_se(name)
      path = asset_path(:loop_se, name) || asset_path(:se, name)
      return unless path

      @mutex.synchronize do
        return if @loop_se_name == name && @loop_se_thread&.alive?
      end

      stop_loop_se

      @mutex.synchronize do
        @loop_se_stop = false
        @loop_se_name = name
        @loop_se_thread = Thread.new do
          if @loop_se_player&.supports_loop
            @loop_se_pid = spawn_player(@loop_se_player, path, loop_playback: true)
            wait_for_channel(:loop_se)
          else
            loop do
              break if channel_stopped?(:loop_se)

              @loop_se_pid = spawn_player(@loop_se_player, path, loop_playback: false)
              wait_for_channel(:loop_se)
              break if channel_stopped?(:loop_se)
            end
          end
        rescue StandardError
          nil
        ensure
          @mutex.synchronize do
            @loop_se_pid = nil
            @loop_se_thread = nil
            @loop_se_name = nil
          end
        end
      end
    end

    def stop_loop_se(name = nil)
      thread = nil
      pid = nil

      @mutex.synchronize do
        return if name && @loop_se_name != name

        @loop_se_stop = true
        thread = @loop_se_thread
        pid = @loop_se_pid
      end

      terminate_process(pid) if pid
      thread&.join(0.5)
    end

    def close
      stop_bgm
      stop_loop_se
    end

    private

    def load_manifest
      path = File.expand_path("../../data/audio/manifest.json", __dir__)
      JSON.parse(File.read(path))
    rescue Errno::ENOENT, JSON::ParserError
      {}
    end

    def detect_player(candidates, prefer_loop:)
      found = candidates.filter_map do |command|
        path = which(command)
        next unless path

        Player.new(command: command, supports_loop: command == "ffplay")
      end

      return found.find(&:supports_loop) if prefer_loop

      found.first
    end

    def which(command)
      ENV.fetch("PATH", "").split(File::PATH_SEPARATOR).each do |dir|
        candidate = File.join(dir, command)
        return candidate if File.executable?(candidate) && !File.directory?(candidate)
      end

      nil
    end

    def asset_path(kind, name)
      relative = @manifest.fetch(kind.to_s, {})[name.to_s]
      return unless relative

      path = File.expand_path("../../#{relative}", __dir__)
      File.file?(path) ? path : nil
    end

    def spawn_player(player, path, loop_playback:, detach: false)
      return unless player

      command = command_for(player.command, path, loop_playback)
      return unless command

      pid = Process.spawn(*command, pgroup: true, out: File::NULL, err: File::NULL)
      Process.detach(pid) if detach
      pid
    end

    def command_for(command, path, loop_playback)
      case command
      when "ffplay"
        ["ffplay", "-nodisp", "-autoexit", "-loglevel", "quiet", ("-loop" if loop_playback), ("0" if loop_playback), path].compact
      when "afplay"
        ["afplay", path]
      when "paplay"
        ["paplay", path]
      when "aplay"
        ["aplay", "-q", path]
      end
    end

    def wait_for_channel(channel)
      pid = nil
      @mutex.synchronize do
        pid = channel == :bgm ? @bgm_pid : @loop_se_pid
      end
      Process.wait(pid) if pid
    rescue Errno::ECHILD
      nil
    end

    def channel_stopped?(channel)
      @mutex.synchronize do
        channel == :bgm ? @bgm_stop : @loop_se_stop
      end
    end

    def terminate_process(pid)
      Process.kill("TERM", -pid)
    rescue Errno::ESRCH
      nil
    end
  end
end
