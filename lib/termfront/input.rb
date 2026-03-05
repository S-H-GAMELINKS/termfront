# frozen_string_literal: true

module Termfront
  class Input
    def initialize
      @key_state = {}
      @pending = +""
      @swap_pressed = false
      @pickup_pressed = false
    end

    def read_keys(stdin)
      keys = []

      while IO.select([stdin], nil, nil, 0)
        begin
          @pending << stdin.read_nonblock(64)
        rescue IO::WaitReadable
          break
        end
      end

      i = 0
      while i < @pending.bytesize
        ch = @pending.getbyte(i)
        if ch == 27
          if @pending.getbyte(i + 1) == 91 && (code = @pending.getbyte(i + 2))
            case code
            when 65 then keys << :up
            when 66 then keys << :down
            when 67 then keys << :right
            when 68 then keys << :left
            end
            i += 3
          else
            keys << :esc
            i += 1
          end
        else
          case ch
          when 119 then keys << :w
          when 97  then keys << :a
          when 115 then keys << :s
          when 100 then keys << :d
          when 32  then keys << :space
          when 113 then keys << :q
          when 116 then keys << :t
          when 101 then keys << :e
          end
          i += 1
        end
      end

      @pending.clear
      keys
    end

    def process(stdin, player: nil)
      keys = read_keys(stdin)

      @key_state.each_key { |k| @key_state[k] -= 1 }
      @key_state.delete_if { |_, v| v <= 0 }
      keys.each { |k| @key_state[k] = Config::KEY_TIMEOUT }

      if player
        if keys.include?(:t)
          unless @swap_pressed
            player.swap_weapon
            @swap_pressed = true
          end
        else
          @swap_pressed = false
        end

        if keys.include?(:e)
          unless @pickup_pressed
            player.try_pickup
            @pickup_pressed = true
          end
        else
          @pickup_pressed = false
        end

        if keys.include?(:space)
          weapon = player.current_weapon
          if weapon.can_fire?(player.last_fire,
                              player.game_time) && (weapon.infinite_ammo? || (weapon.ammo && weapon.ammo > 0))
            player.fire_flash = 4
            weapon.consume_ammo!
            player.last_fire = player.game_time
          end
        end
      end

      keys
    end

    def key?(sym)
      @key_state[sym]
    end

    def clear
      @key_state.clear
      @pending.clear
    end
  end
end
