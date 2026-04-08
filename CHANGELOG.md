# Changelog

All notable changes to KrillClaw will be documented in this file.

Format based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/).

## [Unreleased]

### Added
- ReAct agent loop with autonomous tool execution (`agent.zig`, `react.zig`)
- Multi-provider LLM support: Claude, OpenAI, Ollama (`api.zig`)
- SSE streaming parser with safe string ownership (`stream.zig`)
- Hand-rolled JSON parser/builder — zero dependencies (`json.zig`)
- Compile-time profile system: coding, IoT, robotics (`tools.zig`)
- Coding profile: bash, read/write/edit, search, list_files, apply_patch (`tools_coding.zig`)
- IoT profile: MQTT pub/sub, HTTP, KV store, device info (`tools_iot.zig`)
- Robotics profile: robot commands, e-stop, telemetry (`tools_robotics.zig`)
- BLE GATT transport with desktop simulation via Unix socket (`ble.zig`)
- Serial/UART transport for dev boards (`serial.zig`)
- Abstract vtable transport layer (`transport.zig`)
- Fixed arena allocator for embedded targets: 4K–256K presets (`arena.zig`)
- Context window management with priority-based truncation (`context.zig`)
- FNV-1a stuck-loop detection (constant memory, O(1) per call)
- Config system: file → env → CLI precedence (`config.zig`)
- Sandbox mode for all profiles (`-Dsandbox=true`)
- REPL mode with `/model`, `/provider`, `/help`, `/quit` commands
- Token tracking and usage reporting
- 39 inline unit tests across 6 modules
- 9 integration tests with binary size gate (<300KB)
- Security tests for injection attempts
- CI pipeline (`.github/workflows/test.yml`)

### Security
- BSL 1.1 license applied (Change Date: 2029-02-17, converts to Apache 2.0)
- Path allowlist for file operations (restricted to cwd)
- Bash behind approval gate in coding profile
- No bash access in IoT and robotics profiles
- Rate limiting in IoT (30 req/min) and robotics (10 cmd/s) profiles
- Bounds checking and e-stop in robotics profile

## [0.1.0] — 2026-02-17

Initial source-available release.

[Unreleased]: https://github.com/krillclaw/KrillClaw/compare/v0.1.0...HEAD
[0.1.0]: https://github.com/krillclaw/KrillClaw/releases/tag/v0.1.0
