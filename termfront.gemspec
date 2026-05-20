# frozen_string_literal: true

require_relative "lib/termfront/version"

Gem::Specification.new do |spec|
  spec.name = "termfront"
  spec.version = Termfront::VERSION
  spec.authors = ["S-H-GAMELINKS"]
  spec.email = ["gamelinks007@gmail.com"]

  spec.summary = "Terminal FPS game with raycasting engine"
  spec.description = "A terminal-based first-person shooter with DDA raycasting, campaign mode, and PvP multiplayer."
  spec.homepage = "https://github.com/S-H-GAMELINKS/termfront"
  spec.license = "MIT"
  spec.required_ruby_version = ">= 3.2.0"
  spec.metadata["allowed_push_host"] = "https://rubygems.org"
  spec.metadata["homepage_uri"] = spec.homepage
  spec.metadata["source_code_uri"] = "https://github.com/S-H-GAMELINKS/termfront"
  spec.metadata["changelog_uri"] = "https://github.com/S-H-GAMELINKS/termfront/blob/main/CHANGELOG.md"

  gemspec = File.basename(__FILE__)
  spec.files = IO.popen(%w[git ls-files -z], chdir: __dir__, err: IO::NULL) do |ls|
    ls.readlines("\x0", chomp: true).reject do |f|
      (f == gemspec) ||
        f.start_with?(*%w[bin/ Gemfile .gitignore test/ .github/ .rubocop.yml])
    end
  end
  spec.bindir = "exe"
  spec.executables = spec.files.grep(%r{\Aexe/}) { |f| File.basename(f) }
  spec.require_paths = ["lib"]
end
