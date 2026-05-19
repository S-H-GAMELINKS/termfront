# frozen_string_literal: true

module Termfront
  class Map
    attr_reader :grid, :width, :height

    def initialize(rows)
      @grid = rows.map { |r| r.is_a?(Array) ? r : r.chars }
      @height = @grid.size
      @width = @grid[0].size
    end

    def wall_at?(fx, fy)
      ix = fx.floor
      iy = fy.floor
      return true if iy < 0 || iy >= @height || ix < 0 || ix >= @width

      @grid[iy][ix] == "#"
    end

    def blocked?(px, py, radius = Config::PLAYER_RADIUS)
      wall_at?(px - radius, py - radius) || wall_at?(px + radius, py - radius) ||
        wall_at?(px - radius, py + radius) || wall_at?(px + radius, py + radius)
    end

    def line_of_sight?(x1, y1, x2, y2)
      dx = x2 - x1
      dy = y2 - y1
      dist = Math.sqrt(dx * dx + dy * dy)
      return true if dist < 0.01

      dx /= dist
      dy /= dist

      mx = x1.floor
      my = y1.floor
      ddx = dx == 0 ? 1e30 : (1.0 / dx).abs
      ddy = dy == 0 ? 1e30 : (1.0 / dy).abs

      if dx < 0
        step_x = -1
        sd_x = (x1 - mx) * ddx
      else
        step_x = 1
        sd_x = (mx + 1.0 - x1) * ddx
      end
      if dy < 0
        step_y = -1
        sd_y = (y1 - my) * ddy
      else
        step_y = 1
        sd_y = (my + 1.0 - y1) * ddy
      end

      loop do
        if sd_x < sd_y
          return true if sd_x > dist

          sd_x += ddx
          mx += step_x
        else
          return true if sd_y > dist

          sd_y += ddy
          my += step_y
        end
        return false if my < 0 || my >= @height || mx < 0 || mx >= @width
        return false if @grid[my][mx] == "#"
      end
    end
  end
end
