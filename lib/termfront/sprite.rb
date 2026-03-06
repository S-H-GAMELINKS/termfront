# frozen_string_literal: true

module Termfront
  module Sprite
    module_function

    def executor(nx, ny)
      return "180;120;255" if ((nx - 0.43) / 0.045)**2 + ((ny - 0.11) / 0.045)**2 <= 1.0
      return "180;120;255" if ((nx - 0.57) / 0.045)**2 + ((ny - 0.11) / 0.045)**2 <= 1.0
      return "130;80;220" if ((nx - 0.5) / 0.18)**2 + ((ny - 0.12) / 0.12)**2 <= 1.0
      return "90;50;180" if ((nx - 0.5) / 0.38)**2 + ((ny - 0.30) / 0.08)**2 <= 1.0
      return "80;40;160" if ((nx - 0.5) / 0.25)**2 + ((ny - 0.50) / 0.22)**2 <= 1.0
      return "80;40;160" if ((nx - 0.38) / 0.10)**2 + ((ny - 0.85) / 0.15)**2 <= 1.0
      return "80;40;160" if ((nx - 0.62) / 0.10)**2 + ((ny - 0.85) / 0.15)**2 <= 1.0

      nil
    end

    def crawler(nx, ny)
      return "255;240;100" if ((nx - 0.36) / 0.063)**2 + ((ny - 0.28) / 0.063)**2 <= 1.0
      return "255;240;100" if ((nx - 0.64) / 0.063)**2 + ((ny - 0.28) / 0.063)**2 <= 1.0
      return "220;140;30" if ((nx - 0.5) / 0.40)**2 + ((ny - 0.40) / 0.40)**2 <= 1.0
      return "160;100;20" if ((nx - 0.35) / 0.12)**2 + ((ny - 0.90) / 0.10)**2 <= 1.0
      return "160;100;20" if ((nx - 0.65) / 0.12)**2 + ((ny - 0.90) / 0.10)**2 <= 1.0

      nil
    end

    def player(nx, ny)
      return "140;220;255" if ((nx - 0.43) / 0.045)**2 + ((ny - 0.11) / 0.045)**2 <= 1.0
      return "140;220;255" if ((nx - 0.57) / 0.045)**2 + ((ny - 0.11) / 0.045)**2 <= 1.0
      return "40;130;180" if ((nx - 0.5) / 0.18)**2 + ((ny - 0.12) / 0.12)**2 <= 1.0
      return "30;100;160" if ((nx - 0.5) / 0.38)**2 + ((ny - 0.30) / 0.08)**2 <= 1.0
      return "25;80;140" if ((nx - 0.5) / 0.25)**2 + ((ny - 0.50) / 0.22)**2 <= 1.0
      return "25;80;140" if ((nx - 0.38) / 0.10)**2 + ((ny - 0.85) / 0.15)**2 <= 1.0
      return "25;80;140" if ((nx - 0.62) / 0.10)**2 + ((ny - 0.85) / 0.15)**2 <= 1.0

      nil
    end

    def wall_brightness(dist, side)
      b = 255 - [[(dist * 2.5).to_i, 0].max, 19].min
      b -= 3 if side == 1
      b.clamp(233, 255)
    end

    REGISTRY = {
      executor: method(:executor),
      crawler: method(:crawler),
      player: method(:player)
    }

    def self.for(sprite_id, nx, ny)
      fn = REGISTRY[sprite_id]
      fn ? fn.call(nx, ny) : nil
    end

    def self.register(sprite_id, &block)
      REGISTRY[sprite_id] = block
    end
  end
end
