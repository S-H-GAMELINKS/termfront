# frozen_string_literal: true

module Termfront
  class ScenePlayer
    def initialize(stdout, audio: nil)
      @stdout = stdout
      @audio = audio
    end

    def play(actions, title:, stdin: nil)
      pages = build_pages(actions)
      return if pages.empty?

      if stdin
        play_loop(stdin, pages, title)
      else
        STDIN.raw { |raw| play_loop(raw, pages, title) }
      end
    end

    private

    def play_loop(stdin, pages, title)
      index = 0

      loop do
        render_page(title, pages[index], index + 1, pages.size)

        input = wait_for_advance(stdin)
        return if input == :skip

        @audio&.play_se(:page)
        index += 1
        return if index >= pages.size
      end
    end

    def wait_for_advance(stdin)
      loop do
        next unless IO.select([stdin], nil, nil, Config::FRAME_DT)

        data = stdin.read_nonblock(64)
        data.each_byte do |byte|
          case byte
          when 13, 10, 32
            return :next
          when 27, 81, 113
            return :skip
          end
        end
      rescue IO::WaitReadable
        next
      end
    end

    def render_page(title, page, page_no, page_count)
      rows, cols = @stdout.winsize
      rows = [rows, 12].max
      cols = [cols, 40].max

      buf = +"\e[?2026h\e[H"
      rows.times do |row|
        buf << "\e[#{row + 1};1H\e[K"
      end

      top = " #{title.upcase} "
      buf << "\e[2;3H\e[1;96m#{top}\e[0m"

      if page[:type] == :title_card
        render_title_card_page(buf, rows, cols, page)
      else
        render_text_page(buf, rows, page)
      end

      footer = "[Enter] Next  [Esc] Skip"
      status = "#{page_no}/#{page_count}"
      buf << "\e[#{rows - 1};3H\e[90m#{footer}\e[0m"
      buf << "\e[#{rows - 1};#{[cols - status.size - 1, 1].max}H\e[90m#{status}\e[0m"
      buf << "\e[?2026l"

      TerminalOutput.write_all(@stdout, buf)
    end

    def build_pages(actions)
      rows, cols = @stdout.winsize
      rows = [rows, 12].max
      cols = [cols, 40].max
      max_lines = rows - 8
      width = cols - 4

      actions.flat_map do |action|
        lines = wrap_action(action, width)
        lines.each_slice(max_lines).map do |slice|
          {
            type: action[:type],
            speaker: action[:speaker],
            lines: slice
          }
        end
      end
    end

    def wrap_action(action, width)
      text = action[:text].to_s
      text.split("\n").flat_map do |line|
        wrap_line(line, width)
      end
    end

    def wrap_line(line, width)
      return [""] if line.empty?

      words = line.split(/\s+/)
      return [line[0, width]] if words.empty?

      lines = []
      current = +""
      words.each do |word|
        candidate = current.empty? ? word : "#{current} #{word}"
        if candidate.size <= width
          current = candidate
        else
          lines << current unless current.empty?
          while word.size > width
            lines << word.slice!(0, width)
          end
          current = word
        end
      end
      lines << current unless current.empty?
      lines
    end

    def render_text_page(buf, rows, page)
      if page[:speaker]
        buf << "\e[4;3H\e[1;93m#{page[:speaker]}\e[0m"
      end

      start_row = page[:speaker] ? 6 : 5
      page[:lines].each_with_index do |line, index|
        row = start_row + index
        break if row >= rows - 2

        buf << "\e[#{row};3H#{line}"
      end
    end

    def render_title_card_page(buf, rows, cols, page)
      total_lines = page[:lines].size
      start_row = [[(rows - total_lines) / 2, 4].max, rows - total_lines - 2].min

      page[:lines].each_with_index do |line, index|
        col = [(cols - line.size) / 2 + 1, 1].max
        buf << "\e[#{start_row + index};#{col}H\e[1;97m#{line}\e[0m"
      end
    end
  end
end
