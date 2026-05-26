# frozen_string_literal: true

module Termfront
  module Config
    FRAME_DT      = 1.0 / 60.0
    RENDER_DT     = 1.0 / 60.0
    FOV           = 66.0 * Math::PI / 180.0
    PLAYER_RADIUS = 0.2
    KEY_TIMEOUT   = 5
    ROT_SPEED     = 2.8
    MOVE_SPEED    = 6.0

    CEIL_C  = 17
    FLOOR_C = 234

    ARROWS = ">v<^".chars

    SHIELD_MAX   = 100
    SHIELD_REGEN = 25.0
    SHIELD_DELAY = 3.0

    HEALTH_MAX     = 100
    BEEP_INTERVAL  = 0.15

    PICKUP_RADIUS = 0.8
    TERMINAL_USE_RADIUS = 2.25

    PROJ_SPEED  = 2.5
    PROJ_RADIUS = 0.3

    RADAR_RADIUS = 3
    RADAR_RANGE  = 12.0
    RADAR_RANGE_SQ = RADAR_RANGE * RADAR_RANGE

    PVP_PORT    = 7777
    PVP_DEFAULT_ADDRESS = "termfront.gamelinks007.net:443"
    PVP_HIT_DMG = 10

    DEMO_SPEED = 0.008
  end
end
