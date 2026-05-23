# Changelog

All notable changes to this project will be documented in this file.

The format is based on Keep a Changelog, and this project follows Semantic Versioning as it stabilizes.

## [Unreleased]

### Added

- Added TLS verification coverage for multiplayer connection settings and certificate trust handling

### Changed

- Added visible remote shot tracer effects during PvP and Wavesfight multiplayer matches
- Enabled TLS certificate chain and hostname verification for multiplayer client connections
- Added support for `TERMFRONT_TLS_CERT_FILE` and `TERMFRONT_TLS_KEY_FILE` when loading the server certificate

## [0.1.1] - 2026-05-21

### Changed

- Changed the default multiplayer server address to `termfront.gamelinks007.net:443`

## [0.1.0] - 2026-05-21

Initial public gem release candidate.

### Added

- Terminal FPS core with DDA raycasting renderer
- Singleplayer mission mode
- Campaign mode with multiple missions
- JSON-driven campaign event system
- Story scenes with dialogue and title cards
- In-mission terminal interactions tied to campaign events
- Experimental PvP mode over TCP + TLS
- PvP matchmaking queues for `1v1`, `2v2`, and `4v4`
- Wavesfight PvE mode with stage selection, wave-based survival, and optional 2-player co-op
- External audio manifest and runtime audio playback
- Third-party audio notices for bundled CC0 assets
- Looping shield regeneration audio channel separate from BGM

### Changed

- Improved title/campaign transitions by fixing incomplete terminal writes
- Added terminal markers to the radar and interaction HUD
- Reworked campaign story content and terminal logs
- Replaced placeholder audio mappings with selected CC0 assets for BGM and core SE
- Reworked PvP client/server flow for team-based matches with ally/enemy sync, elimination handling, and team win detection
- Updated PvP spawn placement to use walkable map positions and improved diagonal team separation
- Updated PvP match-size selection to support arrow keys in addition to `J`/`K`
- Disabled quitting PvP matches with `Q` to avoid accidental exits during combat
- Added Wavesfight arena registration for `Corridor Sweep`, `Stronghold`, and `Final Push`
- Added SNI hostname support to TLS client connections for `nginx stream`-based 443 routing

### Notes

- PvP is still considered experimental and needs broader WAN verification
- Audio playback depends on an available local player such as `ffplay`, `afplay`, `paplay`, or `aplay`
