# frozen_string_literal: true

require "io/console"

require_relative "termfront/version"
require_relative "termfront/config"
require_relative "termfront/map"
require_relative "termfront/weapon/base"
require_relative "termfront/weapon/pistol"
require_relative "termfront/weapon/assault_rifle"
require_relative "termfront/weapon/shock_rifle"
require_relative "termfront/weapon/shock_pistol"
require_relative "termfront/drop_item/base"
require_relative "termfront/drop_item/weapon"
require_relative "termfront/enemy/base"
require_relative "termfront/enemy/crawler"
require_relative "termfront/enemy/executor"
require_relative "termfront/projectile"
require_relative "termfront/player"
require_relative "termfront/audio_manager"
require_relative "termfront/mission/base"
require_relative "termfront/mission/event_loader"
require_relative "termfront/mission/event_runtime"
require_relative "termfront/mission/training"
require_relative "termfront/mission/training_grounds"
require_relative "termfront/mission/corridor_sweep"
require_relative "termfront/mission/the_gauntlet"
require_relative "termfront/mission/stronghold"
require_relative "termfront/mission/final_push"
require_relative "termfront/opponent"
require_relative "termfront/sprite"
require_relative "termfront/input"
require_relative "termfront/terminal_output"
require_relative "termfront/renderer"
require_relative "termfront/demo_player"
require_relative "termfront/scene_player"
require_relative "termfront/title_screen"
require_relative "termfront/game"
require_relative "termfront/network/connection"
require_relative "termfront/network/client"
require_relative "termfront/network/server"

module Termfront
  class Error < StandardError; end

  def self.start
    Game.new.start
  end
end
