# Termfront

`Termfront` is a terminal FPS built in Ruby with a raycasting renderer, campaign scripting, audio support, and experimental PvP multiplayer.

## Features

- DDA raycasting renderer for ANSI terminals
- Singleplayer mission mode
- Wavesfight PvE mode with wave-based survival arenas
- Campaign mode with intro/outro scenes and in-mission terminals
- Experimental PvP over TCP + TLS
- Radar, pickups, weapons, shields, and enemy projectiles
- External audio manifest with BGM, SE, and looped shield regeneration audio

## Requirements

- Ruby `>= 3.2`
- A terminal with ANSI escape sequence support
- One of these audio players if you want sound:
  - `ffplay`
  - `afplay`
  - `paplay`
  - `aplay`

RubyGems metadata currently targets Ruby `0.1.1`.

## Installation

If the gem is published:

```bash
gem install termfront
```

For local development from this repository:

```bash
bundle install
bundle exec rake test
bundle exec rake install
```

## Running

Start the game:

```bash
termfront
```

Start a PvP server:

```bash
termfront-server
```

TLS certificate / key paths are **required** for the server to start. Use a fullchain certificate (e.g. issued by Let's Encrypt):

```bash
TERMFRONT_TLS_CERT_FILE=/path/to/fullchain.pem \
TERMFRONT_TLS_KEY_FILE=/path/to/privkey.pem \
termfront-server
```

Use a custom port:

```bash
termfront-server 9000
```

Default PvP port is `7777`.

The default multiplayer client address is `termfront.gamelinks007.net:443`.

Set `TERMFRONT_TLS_CA_FILE` to trust an additional CA certificate when running the client against a server whose certificate chain is not in the system trust store:

```bash
TERMFRONT_TLS_CA_FILE=/path/to/ca.pem termfront
```

## Controls

- `W` `A` `S` `D`: move
- `Left` / `Right`: turn
- `Space`: fire
- `T`: swap weapon
- `E`: interact / pick up / use terminal
- `Q` or `Esc`: quit or back out
- `Enter`: confirm menus

In story scenes:

- `Enter` / `Space`: next page
- `Esc` / `Q`: skip scene

## Modes

### Singleplayer

Quick mission start for testing the core combat loop.

### Campaign

Campaign missions include:

- mission start scenes
- mission complete scenes
- optional in-mission terminal logs

Story/event data lives in `data/events/*.json`.

### Wavesfight

Wavesfight is a PvE survival mode built on selected campaign maps.

- Select from `Corridor Sweep`, `Stronghold`, and `Final Push`
- Survive escalating enemy waves
- Difficulty ramps up every few waves
- Shield, health, and ammo get a partial refresh between waves
- Supports both solo play and 2-player online co-op

### PvP

PvP is currently marked experimental.

- The server listens on TCP and wraps traffic with TLS.
- The client connects directly to `host:port` and verifies the server certificate and hostname.
- The default multiplayer endpoint is `termfront.gamelinks007.net:443`.
- Matchmaking now supports `1v1`, `2v2`, and `4v4`.
- Players choose the match size on the client, and the server keeps separate queues for each mode.
- Team matches end when one side is fully eliminated.
- Local relay/start/state/ping behavior is covered by tests.
- Internet/WAN play still needs broader real-world verification.

For internet testing, the simplest setups are:

- direct TCP port forwarding to the host running `termfront-server`
- `nginx stream` TCP passthrough on a VPS
- a mesh/VPN overlay such as Tailscale

## Audio

Audio mappings are defined in:

- [data/audio/manifest.json](data/audio/manifest.json)

Third-party audio notices are tracked here:

- [data/audio/THIRD_PARTY_NOTICES.md](data/audio/THIRD_PARTY_NOTICES.md)

If no supported audio player is available, the game still runs without sound.

## Development

Run tests:

```bash
ruby -Itest test/test_termfront.rb
```

Build the gem:

```bash
gem build termfront.gemspec
```

Install the built gem locally:

```bash
gem install ./termfront-0.1.1.gem
```

## License

Code is available under the [MIT License](LICENSE.txt).

Third-party audio assets remain under their own licenses as documented in [data/audio/THIRD_PARTY_NOTICES.md](data/audio/THIRD_PARTY_NOTICES.md).
