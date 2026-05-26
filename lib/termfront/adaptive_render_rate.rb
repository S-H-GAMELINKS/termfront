# frozen_string_literal: true

module Termfront
  module AdaptiveRenderRate
    OVER_BUDGET_RATIO  = 0.85
    UNDER_BUDGET_RATIO = 0.5
    DOWNSHIFT_FRAMES   = 30
    UPSHIFT_FRAMES     = 60

    @current_dt = Config::RENDER_DT
    @over_budget_count = 0
    @under_budget_count = 0

    class << self
      def current_dt
        @current_dt
      end

      def observe(spent)
        if spent > Config::FRAME_DT * OVER_BUDGET_RATIO
          @over_budget_count += 1
          @under_budget_count = 0
          if @over_budget_count >= DOWNSHIFT_FRAMES && @current_dt < Config::RENDER_DT_LOW
            @current_dt = Config::RENDER_DT_LOW
          end
        elsif spent < Config::FRAME_DT * UNDER_BUDGET_RATIO
          @under_budget_count += 1
          @over_budget_count = 0
          if @under_budget_count >= UPSHIFT_FRAMES && @current_dt > Config::RENDER_DT
            @current_dt = Config::RENDER_DT
          end
        end
      end

      def reset!
        @current_dt = Config::RENDER_DT
        @over_budget_count = 0
        @under_budget_count = 0
      end
    end
  end
end
