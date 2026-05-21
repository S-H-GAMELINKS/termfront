# frozen_string_literal: true

module Termfront
  class RemoteEnemy
    attr_accessor :id, :x, :y, :hp, :max_hp, :alive

    def initialize(id:, x:, y:, sprite_id:, hp:, max_hp:, alive: true)
      @id = id
      @x = x
      @y = y
      @sprite_id = sprite_id
      @hp = hp
      @max_hp = max_hp
      @alive = alive
    end

    def sprite_id
      @sprite_id
    end
  end
end
