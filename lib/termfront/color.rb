# frozen_string_literal: true

module Termfront
  module Color
    module_function

    def rgb_to_256(r, g, b)
      if (r - g).abs < 8 && (g - b).abs < 8 && (r - b).abs < 8
        avg = (r + g + b) / 3
        return 16 if avg < 8
        return 231 if avg > 247

        232 + (avg - 8) * 23 / 240
      else
        16 + (r * 5 / 255) * 36 + (g * 5 / 255) * 6 + (b * 5 / 255)
      end
    end
  end
end
