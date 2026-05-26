# frozen_string_literal: true

module Termfront
  module Sprite
    module_function

    EXECUTOR_EYE  = Color.rgb_to_256(180, 120, 255)
    EXECUTOR_HEAD = Color.rgb_to_256(130, 80, 220)
    EXECUTOR_NECK = Color.rgb_to_256(90, 50, 180)
    EXECUTOR_BODY = Color.rgb_to_256(80, 40, 160)

    CRAWLER_EYE  = Color.rgb_to_256(255, 240, 100)
    CRAWLER_BODY = Color.rgb_to_256(220, 140, 30)
    CRAWLER_LEG  = Color.rgb_to_256(160, 100, 20)

    PLAYER_EYE  = Color.rgb_to_256(140, 220, 255)
    PLAYER_HEAD = Color.rgb_to_256(40, 130, 180)
    PLAYER_NECK = Color.rgb_to_256(30, 100, 160)
    PLAYER_BODY = Color.rgb_to_256(25, 80, 140)

    DUMMY_HEAD  = Color.rgb_to_256(235, 80, 80)
    DUMMY_TORSO = Color.rgb_to_256(210, 210, 210)
    DUMMY_LOWER = Color.rgb_to_256(200, 200, 200)
    DUMMY_LEG   = Color.rgb_to_256(180, 180, 180)

    def executor(nx, ny)
      return EXECUTOR_EYE  if ((nx - 0.43) / 0.045)**2 + ((ny - 0.11) / 0.045)**2 <= 1.0
      return EXECUTOR_EYE  if ((nx - 0.57) / 0.045)**2 + ((ny - 0.11) / 0.045)**2 <= 1.0
      return EXECUTOR_HEAD if ((nx - 0.5) / 0.18)**2 + ((ny - 0.12) / 0.12)**2 <= 1.0
      return EXECUTOR_NECK if ((nx - 0.5) / 0.38)**2 + ((ny - 0.30) / 0.08)**2 <= 1.0
      return EXECUTOR_BODY if ((nx - 0.5) / 0.25)**2 + ((ny - 0.50) / 0.22)**2 <= 1.0
      return EXECUTOR_BODY if ((nx - 0.38) / 0.10)**2 + ((ny - 0.85) / 0.15)**2 <= 1.0
      return EXECUTOR_BODY if ((nx - 0.62) / 0.10)**2 + ((ny - 0.85) / 0.15)**2 <= 1.0

      nil
    end

    def crawler(nx, ny)
      return CRAWLER_EYE  if ((nx - 0.36) / 0.063)**2 + ((ny - 0.28) / 0.063)**2 <= 1.0
      return CRAWLER_EYE  if ((nx - 0.64) / 0.063)**2 + ((ny - 0.28) / 0.063)**2 <= 1.0
      return CRAWLER_BODY if ((nx - 0.5) / 0.40)**2 + ((ny - 0.40) / 0.40)**2 <= 1.0
      return CRAWLER_LEG  if ((nx - 0.35) / 0.12)**2 + ((ny - 0.90) / 0.10)**2 <= 1.0
      return CRAWLER_LEG  if ((nx - 0.65) / 0.12)**2 + ((ny - 0.90) / 0.10)**2 <= 1.0

      nil
    end

    def player(nx, ny)
      return PLAYER_EYE  if ((nx - 0.43) / 0.045)**2 + ((ny - 0.11) / 0.045)**2 <= 1.0
      return PLAYER_EYE  if ((nx - 0.57) / 0.045)**2 + ((ny - 0.11) / 0.045)**2 <= 1.0
      return PLAYER_HEAD if ((nx - 0.5) / 0.18)**2 + ((ny - 0.12) / 0.12)**2 <= 1.0
      return PLAYER_NECK if ((nx - 0.5) / 0.38)**2 + ((ny - 0.30) / 0.08)**2 <= 1.0
      return PLAYER_BODY if ((nx - 0.5) / 0.25)**2 + ((ny - 0.50) / 0.22)**2 <= 1.0
      return PLAYER_BODY if ((nx - 0.38) / 0.10)**2 + ((ny - 0.85) / 0.15)**2 <= 1.0
      return PLAYER_BODY if ((nx - 0.62) / 0.10)**2 + ((ny - 0.85) / 0.15)**2 <= 1.0

      nil
    end

    def training_dummy(nx, ny)
      return DUMMY_HEAD  if ((nx - 0.5) / 0.18)**2 + ((ny - 0.18) / 0.14)**2 <= 1.0
      return DUMMY_TORSO if ((nx - 0.5) / 0.08)**2 + ((ny - 0.42) / 0.14)**2 <= 1.0
      return DUMMY_LOWER if ((nx - 0.5) / 0.22)**2 + ((ny - 0.66) / 0.12)**2 <= 1.0
      return DUMMY_LEG   if ((nx - 0.38) / 0.08)**2 + ((ny - 0.90) / 0.12)**2 <= 1.0
      return DUMMY_LEG   if ((nx - 0.62) / 0.08)**2 + ((ny - 0.90) / 0.12)**2 <= 1.0

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
      player: method(:player),
      training_dummy: method(:training_dummy)
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
