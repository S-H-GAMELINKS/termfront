# Changelog

All notable changes to this project will be documented in this file.

The format is based on Keep a Changelog, and this project follows Semantic Versioning as it stabilizes.

## [Unreleased]

### Changed

- Memoize the HUD shield and ammo lines so `fit_ansi` only re-runs when the shown shield value, weapon, ammo, pickup hint, or terminal width actually change
- Inline the color-mode branching and SGR lookups into `Renderer#render_view` to remove per-cell `bg_only?`, `ansi_fg`, and `ansi_bg` method calls (about 72,000 calls per second at 30 Hz on an 80-wide terminal)
- Enable YJIT on startup so the hot Ruby methods in the renderer (`build_view_pixels`, `render_view`, `cast_ray`, etc.) get JIT-compiled instead of interpreted
- Rewrite `TerminalOutput.fit_ansi` to walk the input by byte index with `getbyte` and `byteslice` instead of scanning with a regular expression, removing the per-line `Regexp#match` / `MatchData` allocations that dominated the renderer's CPU profile under YJIT
- Render the title screen at 30 Hz while still advancing its spin animation and polling input at 60 Hz, so the per-frame renderer cost halves without making the demo motion feel choppy
- Cache the demo mission instance, its tile-map, and its enemy definitions inside `TitleScreen#initialize` instead of rebuilding them every frame
- Render singleplayer and Wavesfight at 30 Hz while still running the update step, physics, and input polling at 60 Hz, halving the in-game renderer cost without slowing the simulation or input response
- Rewrite `Renderer#build_view_pixels` with column-major `while` loops that read `wtop`/`wbot`/`wcol` once per column and fill the ceiling / wall / floor segments without per-cell branching, hoisting `Config::CEIL_C` / `Config::FLOOR_C` and `@pixels` as locals so YJIT keeps the hot loop tight
- Memoize the title screen's static lines (logo, subtitle, and the five menu entries) per terminal width so `fit_ansi` runs once instead of seven times per title-screen frame
- Memoize every line of `Game#render_mission_select` keyed by terminal width, current selection, difficulty, and mission class, so the nine `fit_ansi` calls per frame collapse to cache lookups while the cursor is idle
- Reuse the radar's enemy / drop / terminal / ally cell hashes between frames and key them by integer (`sy * diam + sx`) to drop per-cell `Array` allocations, hoisting `Config::RADAR_RANGE`, `RADAR_RANGE_SQ`, `r*r`, and the player position as locals so YJIT keeps the radar projection loops tight
- Tighten the enemy half of `Renderer#overlay_enemies_3d`: hoist the FOV tangent, player position, and half-frame constants as locals, replace the `upto` loops with `while`, use integer shift instead of `to_f` / `.ceil` / `.floor` for half-block row indexing, and cache the float versions of `actual_h` / `actual_w` so the per-cell sprite division loop stops allocating new floats every iteration
- Apply the same `while`-loop and integer-math pattern to the drop and projectile branches of `Renderer#overlay_enemies_3d`, reusing the hoisted player position and half-frame constants and computing the projectile color directly instead of through an intermediate ANSI code string

## [0.1.5] - 2026-05-25

### Changed

- Radar distance culling now compares squared distances against `Config::RADAR_RANGE_SQ` instead of taking a square root per entity per frame
- Renderer reuses the per-column raycast buffers and the virtual pixel grid across frames instead of allocating fresh arrays each tick, only re-allocating when the terminal is resized
- Build the radar background grid, horizontal rule, and ANSI-styled radar glyphs once and reuse them across frames
- Look up 256-color SGR escape sequences from a precomputed table and memoize truecolor SGR sequences to avoid rebuilding the same ANSI strings every cell
- Reuse renderer sprite collection arrays and the radar line buffer across frames, and sort sprites with a comparator block instead of `sort_by`
- Cache the terminal `winsize` inside the renderer and invalidate the cache from a `SIGWINCH` handler instead of issuing an ioctl every frame
- PvP hit raycast now culls candidates beyond `MAX_PVP_RANGE` and skips the line-of-sight check when the candidate is already farther than the current best
- Multiplayer server `broadcast` now serializes each outgoing message once and writes the same JSON line to every recipient
- PvP server now aggregates outgoing player state on a 30 Hz server tick instead of relaying each incoming state message immediately, reducing TLS write bursts on small VMs
- PvP match loop `IO.select` timeout shortened from 500 ms to ~16 ms so the new 30 Hz broadcast tick is not delayed by idle reads
- PvP client opponent interpolation now converges within ~40 ms (lerp factor raised from 15 to 25) so remote players track the new 30 Hz broadcast tick within a single frame
- Run the title demo, campaign missions, Wavesfight, and PvP at 60 FPS

### Removed

- Stopped emitting DEC 2026 synchronized update escape sequences around each frame and removed the `TERMFRONT_SYNC_UPDATES` environment switch; non-supporting terminals (some SSH paths, older xterm) were paying parsing cost for shapes they ignore, while supporting terminals show no visible regression

### Fixed

- Wavesfight wave advance now fully restores each surviving and revived player's shield to `Config::SHIELD_MAX`; previously only a +35 partial recovery was applied, which left revived players at 35%

## [0.1.34] - 2026-05-25

### Fixed

- Fixed PvP `route_hit` so the server always sends the fixed `Config::PVP_HIT_DMG` damage value, ignoring the attacker-supplied `d` field
- Require `TERMFRONT_TLS_CERT_FILE` and `TERMFRONT_TLS_KEY_FILE` to be set and point to existing PEM files; removed the self-signed certificate generation fallback
- Enforce TLS 1.2 as the minimum protocol version on both the multiplayer server and client
- Stop logging client peer IP addresses on the multiplayer server
- Connect multiplayer clients to the official server address only; remove the free-form server address input
- Restrict audio manifest entries to paths under `data/audio/`
- Reject Wavesfight co-op queue requests with unknown mission ids
- Guard match worker threads against uncaught exceptions and ensure player sockets are closed
- Cap each matchmaking queue at 64 waiting players and reject excess connections
- Move per-connection handshake off the accept loop and drop silent clients after a short timeout
- Cap server and client receive buffers and disconnect peers that flood bytes without a newline
- End multiplayer matches after a maximum duration or when all players have been idle
- Restrict the weapon field on multiplayer state messages to the legal loadout (`pistol`, `ar`)
- Validate enemy / weapon / projectile type symbols received from the server against a fixed whitelist on the client side before converting to symbols
- Validate position, ammo, and fire-flash fields on Wavesfight co-op state messages; reject the update when position is non-finite or outside the map
- Validate PvP state fields (position, shield, health, ammo, fire-flash) before relaying to opponents; drop the relay when position is non-finite or outside the map
- Reject multiplayer state messages whose position delta exceeds the maximum physical step from the previous server-known position
- Rate-limit incoming multiplayer messages per type per player; sustained overflow ends the match for the offending client
- Track PvP shield and health on the server; the server applies hit damage, regenerates shields between hits, and uses authoritative values when relaying state to opponents
- Determine PvP hit targets server-side via raycast from the attacker's known position and facing; enforce weapon cooldown, firing cone, line-of-sight, and team checks instead of trusting the attacker-supplied target id
- Wavesfight co-op shield no longer stays depleted: the server now regenerates shield and health after `Config::SHIELD_DELAY`, and the client plays the shield regeneration loop SE while regen is active
- Wavesfight co-op now restores shield, health, and revives downed players between waves to match singleplayer behavior
- Final Push: relocated the rightmost crawler off the dividing wall so it can be killed and the mission can complete

### Added

- Honor `TERMFRONT_TLS_CA_FILE` on multiplayer clients to trust an additional CA certificate
- Optional shared-token authentication via `TERMFRONT_PVP_TOKEN`; when set on the server, queue requests must carry a matching token (sent automatically when the client has the same env var)
- Wavesfight co-op now generates weapon drops when enemies are killed; the `E` key picks up the nearest drop within `Config::PICKUP_RADIUS`, swapping the current weapon (which is dropped at the player's position) and tracking obtained weapons per-player so cheaters cannot claim weapons they have not picked up

## [0.1.3] - 2026-05-24

### Fixed

- Fixed TLS server certificate loading to include intermediate certificates from `fullchain.pem`, allowing clients to verify Let's Encrypt chains correctly

## [0.1.2] - 2026-05-23

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
