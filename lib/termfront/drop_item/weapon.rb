# frozen_string_literal: true

module Termfront
  module DropItem
    class Weapon < Base
      attr_accessor :type, :ammo

      def initialize(x:, y:, type:, ammo:)
        super(x: x, y: y)
        @type = type
        @ammo = ammo
      end

      def pickup!(player)
        cur = player.current_weapon
        if cur.type_id == @type
          max = cur.max_ammo
          cur.ammo = [cur.ammo + @ammo, max].min if max
        else
          player.drops << DropItem::Weapon.new(x: player.x, y: player.y, type: cur.type_id, ammo: cur.ammo)
          player.weapons[player.weapon_idx] = Weapon::Base.build(@type, @ammo)
        end
      end

      def sprite_color
        @type.to_s.start_with?("shock") ? "60;200;220" : "220;200;60"
      end

      def radar_color
        @type.to_s.start_with?("shock") ? "\e[96m" : "\e[93m"
      end

      def radar_label
        Weapon::Base.registry[@type].new.name[0]
      end
    end
  end
end
