<h1 align="center">
  <br>
  NanoAgent
  <br>
</h1>

<p align="center">
  <strong>An exploratory autonomous AI agent runtime written in Zig.</strong><br>
  <em>No external packages. Cross-compiles to small static binaries, from servers down to bare-metal MCU stubs.</em>
</p>

<p align="center">
  <a href="LICENSE"><img src="https://img.shields.io/badge/license-BSL_1.1-blue?style=flat-square" alt="License: BSL 1.1"></a>
  <img src="https://img.shields.io/badge/language-Zig_0.15+-f7a41d?style=flat-square&logo=zig&logoColor=white" alt="Zig 0.15+">
  <img src="https://img.shields.io/badge/dependencies-0-brightgreen?style=flat-square" alt="Zero deps">
  <img src="https://img.shields.io/badge/inline_tests-126-blue?style=flat-square" alt="126 inline tests">
</p>

<p align="center">
  <a href="#quick-start">Quick Start</a> &middot;
  <a href="#what-this-is">What This Is</a> &middot;
  <a href="#architecture">Architecture</a> &middot;
  <a href="#profiles">Profiles</a> &middot;
  <a href="#embedded-status">Embedded Status</a> &middot;
  <a href="#configuration-reference">Config</a> &middot;
  <a href="CONTRIBUTING.md">Contributing</a>
</p>

---

NanoAgent is an agent runtime written from scratch in **Zig** — no external packages, no
`std.json`, no runtime dependencies. It implements a **ReAct (Reason + Act) loop** that calls
an LLM, parses the response, executes tools, and repeats until the task finishes or an
iteration cap is hit. Around that core sit a hand-rolled JSON parser, an SSE streaming
parser, a compile-time tool-profile system, a fixed arena allocator, a cron scheduler, and
three transport backends.

```
 27 Zig source files  ·  6,917 lines  ·  126 inline tests  ·  0 dependencies
 3 compile-time profiles  ·  3 transports  ·  7 bridge channels
```

## Project status

This is a **single-commit exploratory project**, and the honest framing matters more than
the numbers:

- **There is no CI.** `.github/` contains issue and pull-request templates only — there is
  no `workflows/` directory, and this repository has never run a GitHub Actions job. Earlier
  versions of this README claimed "CI runs on every push with a binary size gate (< 600 KB)";
  that was never true and has been removed.
- **Boot time and idle RAM have never been measured.** Claims of "boots in under 10 ms" and
  "runs on 2 MB of RAM" had no benchmark behind them anywhere in this tree and are gone.
  There is no benchmark harness here.
- **No build has been run on physical hardware.** See [Embedded status](#embedded-status)
  — the MCU targets compile, but they are stubs without a hardware abstraction layer.
- **Binary sizes are cross-compile measurements only**, recorded in
  [`Docs/CROSS-CHECK-RESULTS.md`](Docs/CROSS-CHECK-RESULTS.md) (2026-02-28, Zig 0.15.2,
  macOS arm64 host, executed under Docker/QEMU user-mode).

## What This Is

The core of an agent — *call LLM, parse response, execute tools, repeat* — is not much code.
Most runtimes bury it under a language runtime and a dependency tree. This project is an
attempt to write that loop directly, in a language with no runtime, and see how far down it
goes.

What that buys you, concretely: a single static binary, cross-compiled by Zig to 10 Linux
architectures with no external toolchain, with compile-time dead-code elimination of whole
tool categories.

What it does not buy you: a production agent. See [Known Limitations](#known-limitations).

### Verified build results

From [`Docs/CROSS-CHECK-RESULTS.md`](Docs/CROSS-CHECK-RESULTS.md) — 44 configurations:

| Category | Configs | Level of proof |
|---|:--:|---|
| Linux, executed under Docker + QEMU multiarch | 18 | compile + link + run `--version` and `--help` |
| Linux, compile-only (no Docker base image) | 12 | compile + link |
| macOS arm64, native | 1 | full test suite |
| Freestanding generic (ARM, AArch64, RISC-V) | 5 | compile + link + ELF validation |
| Freestanding MCU-specific (8 Cortex-M variants) | 8 | compile + link, **needs HAL to run** |

Binary sizes for the executed Linux targets, `ReleaseSmall`:

| Target | coding | iot | robotics |
|---|--:|--:|--:|
| aarch64-linux | 452 KB | 432 KB | 450 KB |
| x86_64-linux | 526 KB | 502 KB | 520 KB |
| arm-linux (ARMv7) | 547 KB | 525 KB | 545 KB |
| riscv64-linux | 588 KB | 570 KB | 588 KB |
| powerpc64le-linux | 543 KB | 519 KB | 539 KB |
| s390x-linux | 677 KB | 648 KB | 659 KB |

macOS arm64 native: 508 KB. Compile-only targets range higher — up to 887 KB on
mipsel-linux. The often-quoted "~450 KB" is the *smallest* executed configuration, not a
general figure; plan on roughly **430–890 KB depending on target and profile**.

## Quick Start

```bash
# 1. Install Zig 0.15+ (https://ziglang.org/download/)

# 2. Clone and build
git clone https://github.com/nitishsjsucs/NanoAgent.git
cd NanoAgent
zig build -Doptimize=ReleaseSmall

# 3. Set your API key
export ANTHROPIC_API_KEY=sk-ant-...

# 4. One-shot mode — run a single task and exit
./zig-out/bin/nanoagent "create a REST API in Go with user auth"

# 5. Interactive REPL
./zig-out/bin/nanoagent
```

No npm, no pip, no container runtime. Zig's own toolchain cross-compiles without any
external cross-toolchain.

## Architecture

```
┌──────────────────────────────────────────────────────────────────┐
│                           NanoAgent                              │
│                                                                  │
│  ┌──────────┐    ┌───────────┐    ┌──────────────┐              │
│  │  main    │───▶│  agent    │───▶│   tools      │              │
│  │  (CLI /  │    │  (ReAct   │    │  (comptime   │              │
│  │   REPL)  │    │   loop)   │    │   dispatch)  │              │
│  └──────────┘    └─────┬─────┘    └──────┬───────┘              │
│                        │                 │                       │
│                   ┌────▼──────┐    ┌─────▼────────────────┐     │
│                   │   api     │    │  tools_coding.zig     │     │
│                   │ (client)  │    │  tools_iot.zig        │     │
│                   └────┬──────┘    │  tools_robotics.zig   │     │
│                        │           │  tools_shared.zig     │     │
│                 ┌──────▼───────┐   └──────────────────────┘     │
│                 │  transport   │  ◀── vtable dispatch            │
│                 └──┬────┬───┬──┘                                 │
│                    │    │   │                                     │
│                ┌───▼┐ ┌─▼──┐ ┌▼─────┐                            │
│                │HTTP│ │BLE │ │Serial│                            │
│                └────┘ └────┘ └──────┘                            │
│                                                                  │
│  Core:  json.zig · stream.zig · context.zig · react.zig          │
│  Infra: config.zig · types.zig · arena.zig · cron.zig            │
│  Edge:  ble.zig · serial.zig · transport.zig · fault_log.zig     │
│  Lite:  sensor.zig · swarm.zig · power.zig · trigger.zig ·       │
│         event_queue.zig                                          │
└──────────────────────────────────────────────────────────────────┘
```

### What is actually interesting in here

Four things in this codebase are worth a look regardless of the project's maturity:

**Compile-time tool profiles.** `tools.zig` selects its profile module with a `comptime`
switch on a build option:

```zig
const profile_mod = switch (build_options.profile) {
    .coding => @import("tools_coding.zig"),
    .iot => @import("tools_iot.zig"),
    .robotics => @import("tools_robotics.zig"),
};
```

Unselected profiles are never imported, so their code is not in the binary at all. The IoT
build contains no `bash` tool — not disabled at runtime, *absent*. That makes "the IoT
profile cannot shell out" a property of the build rather than a policy check, which is a
genuinely nice use of Zig's comptime.

**Integer-only signal processing for FPU-less MCUs.** `sensor.zig` implements a ring buffer,
rolling average and Z-score anomaly detection entirely in integer math, so it runs on
Cortex-M0 parts with no floating-point unit. 14 inline tests.

**A fixed arena allocator with no free.** `arena.zig` provides `FixedArena(comptime size)`
over a statically sized buffer — no `mmap`, no `sbrk` — reset in one operation between agent
turns. Preset sizes range from 4 KB to 256 KB. It tracks peak usage and has integer-overflow
guards. 7 inline tests.

**Zero-allocation SSE event dispatch.** `stream.zig` parses the event stream into a typed
enum by comparing against string literals ordered by expected frequency, so the common
`content_block_delta` case matches first and no allocation happens for event typing.

### Source map

All 27 files in `src/`, with line counts and inline test counts measured from this checkout:

| File | LOC | Tests | Purpose |
|------|----:|------:|---------|
| `json.zig` | 545 | 12 | Hand-rolled JSON builder + string-aware key extractor |
| `tools_coding.zig` | 505 | 4 | Coding tools: bash, read/write/edit, search, list, patch, glob |
| `tools_shared.zig` | 431 | 5 | Cross-profile tools: time, KV store, web search, sessions, OTA |
| `sensor.zig` | 429 | 14 | Ring buffer + integer-only Z-score anomaly detection |
| `stream.zig` | 378 | 5 | SSE parser with zero-allocation event type dispatch |
| `swarm.zig` | 368 | 11 | Multi-agent coordination primitives for edge devices |
| `agent.zig` | 316 | 3 | Agent loop: LLM calls, tool dispatch, streaming, error recovery |
| `main.zig` | 314 | 0 | Entry point: CLI parsing, REPL, cron daemon, embedded mode |
| `cron.zig` | 295 | 10 | Interval scheduler for daemon mode (no threads) |
| `event_queue.zig` | 280 | 8 | Offline event buffer, drains to gateway on reconnect |
| `tools_iot.zig` | 269 | 3 | IoT tools: MQTT, HTTP, GPIO bridge, device info |
| `context.zig` | 234 | 6 | Token estimation + priority-based context truncation |
| `trigger.zig` | 219 | 9 | Local threshold rule engine, evaluated without the LLM |
| `power.zig` | 218 | 8 | Per-subsystem energy budget estimator |
| `arena.zig` | 210 | 7 | Fixed arena allocator with last-alloc resize optimisation |
| `tools.zig` | 205 | 11 | Tool dispatcher: shared → profile → bridge fallback chain |
| `config.zig` | 202 | 0 | Config loading: file → env → CLI precedence |
| `api_parse.zig` | 190 | 1 | Response parsing shared by the HTTP and BLE clients |
| `transport.zig` | 179 | 4 | Abstract vtable transport + BLE/Serial RPC protocol |
| `api.zig` | 170 | 0 | HTTP LLM client with streaming |
| `tools_robotics.zig` | 159 | 0 | Robotics tools: motion commands, e-stop, telemetry |
| `types.zig` | 158 | 0 | Core types: Provider, Message, Config, ToolDef, ContentBlock |
| `ble.zig` | 155 | 0 | BLE GATT transport (SoftDevice integration points) |
| `fault_log.zig` | 151 | 5 | Boot breadcrumbs so the LLM can diagnose after a reset |
| `serial.zig` | 142 | 0 | UART transport with length-prefixed framing |
| `react.zig` | 104 | 0 | ReAct orchestration: classify → extract thought → execute |
| `api_ble.zig` | 91 | 0 | LLM client over BLE RPC, replaces `api.zig` when embedded |
| **Total** | **6,917** | **126** | |

## Profiles

Compile-time profiles select tool sets via `comptime`. Only the selected profile's code
reaches the binary.

```bash
zig build -Dprofile=coding -Doptimize=ReleaseSmall     # bash, file I/O, search, patch
zig build -Dprofile=iot -Doptimize=ReleaseSmall        # MQTT, HTTP, GPIO bridge
zig build -Dprofile=robotics -Doptimize=ReleaseSmall   # motion, e-stop, telemetry
```

## Providers

`types.zig` defines **three** native provider backends:

| Provider | Endpoint |
|---|---|
| `claude` | `https://api.anthropic.com` `/v1/messages` |
| `openai` | `https://api.openai.com` `/v1/chat/completions` |
| `ollama` | local `/api/chat` |

Any other OpenAI-compatible service works through the `openai` backend by overriding
`--base-url` — Groq, DeepSeek, Together, OpenRouter and Gemini's compatibility layer are
documented in [`Docs/PROVIDERS.md`](Docs/PROVIDERS.md). That is a pass-through, not
per-provider support: there are three code paths, not twenty.

```bash
nanoagent --provider claude --model claude-sonnet-4-5-20250929 "hello"
nanoagent --provider ollama --model llama3.2 "hello"
nanoagent --provider openai --base-url https://api.groq.com/openai \
          --model llama-3.3-70b-versatile "hello"
```

## Embedded Status

The intended design splits work between a device and a bridge: the device runs the agent
loop and JSON parsing; a phone or PC bridges network access and tool execution.

```
┌──────────────┐       BLE / UART       ┌───────────────┐      HTTPS      ┌─────────┐
│  NanoAgent   │ ◄─────────────────────► │    Bridge      │ ◄────────────► │  LLM    │
│  (device)    │                         │  (phone/PC)    │                │  API    │
│  Agent loop  │ ──────────────────────► │ Execute tools  │                └─────────┘
│  JSON parse  │ ◄────────────────────   │ Forward to API │
└──────────────┘                         └────────────────┘
```

**This path is not yet working on hardware.** Be clear about what the build results mean:

| Target class | Status |
|---|---|
| Linux (6 architectures) | Runs `--version` / `--help` under QEMU user-mode |
| macOS arm64 | Runs natively, test suite passes |
| Cortex-M0/M3/M4/M7/M23/M33/M55 | **Compiles and links only.** Output is a 432–436 byte stub with no board HAL. Running it needs HAL integration plus Renode or QEMU system-mode. |
| RISC-V freestanding (ESP32-C3/C6/H2 class) | **Compiles only**, 496 byte stub |
| Original ESP32 (Xtensa) | **Not supported** — Zig 0.15 has no Xtensa backend |
| wasm32 | **Not supported** — `std.http` / `std.fs` need rearchitecting |

Previous versions of this README published a "Target Hardware" table listing ESP32-C3,
Raspberry Pi Pico W, Colmi R02, nRF52840-DK and nRF5340-DK with RAM, flash, cost and
transport columns, implying validated deployments. No board in that table has ever run this
code. The table is removed; the compile-target mapping in
[`Docs/CROSS-CHECK-RESULTS.md`](Docs/CROSS-CHECK-RESULTS.md) is the accurate version, and it
labels every bare-metal entry compile-only.

### Fixed Arena Allocator

`arena.zig` sizes: `Arena4K`, `Arena16K`, `Arena32K`, `Arena128K`, `Arena256K`. These are
allocator presets chosen with particular device classes in mind; they are not measured
footprints on those devices.

## Transport Layers

`transport.zig` defines a vtable interface with three implementations: HTTP (`api.zig`),
BLE GATT (`ble.zig`, with Nordic SoftDevice integration points), and UART
(`serial.zig`, length-prefixed framing, baud set via `stty` on Linux/macOS).

```bash
zig build -Dble=true -Doptimize=ReleaseSmall
zig build -Dserial=true -Doptimize=ReleaseSmall
zig build -Dembedded=true -Doptimize=ReleaseSmall   # swaps api.zig → api_ble.zig
```

## Cron / Heartbeat (Daemon Mode)

`cron.zig` is an interval scheduler that uses no threads. Intervals are in **seconds**.

```bash
# Run the agent every 5 minutes with a fixed prompt
nanoagent --cron-interval 300 --cron-prompt "check sensor readings"

# Heartbeat every 60s alongside a 10-minute agent interval
nanoagent --cron-interval 600 --cron-prompt "..." --heartbeat 60

# Run exactly 10 times, then exit
nanoagent --cron-interval 60 --cron-prompt "..." --cron-max-runs 10
```

## Messaging Channels

Seven channel adapters live in the Python bridge (`bridge/bridge/channels/`): Discord,
MQTT, Slack, Telegram, WhatsApp, webhook and WebSocket. These are bridge-side Python, not
Zig — the Zig binary reaches them through the bridge RPC protocol.

## MCP Support

`bridge/bridge/mcp_bridge.py` exposes MCP tools to the agent through the same bridge
channel.

## GPIO / Hardware Control

GPIO tools route through the Python bridge: real hardware via `libgpiod` on Linux,
simulator mode (logging only) on macOS and Windows.

## Skills / Plugins

`bridge/bridge/plugins.py` loads Python plugins from `~/.nanoagent/plugins/` with lifecycle
hooks and capability declaration.

## Configuration Reference

Precedence: **CLI flags → environment variables → config file → defaults**
(`config.zig`).

### CLI flags

```
--provider <claude|openai|ollama>   --model <name>
--base-url <url>                    --transport <http|ble|serial>
--ble-device <id>                   --serial-port <path>
--cron-interval <seconds>           --cron-prompt <text>
--cron-max-runs <n>                 --heartbeat <seconds>
--prompt <text>                     --no-stream
--version                           --help
```

### Environment variables

```
ANTHROPIC_API_KEY          OPENAI_API_KEY
NANOAGENT_PROVIDER         NANOAGENT_MODEL
NANOAGENT_BASE_URL         NANOAGENT_TRANSPORT
NANOAGENT_BLE_DEVICE       NANOAGENT_SERIAL_PORT
NANOAGENT_MAX_TOKENS       NANOAGENT_SYSTEM_PROMPT
```

## Design Decisions

- **No `std.json`.** `json.zig` is a hand-rolled builder and extractor, so the parser works
  on freestanding targets where the standard library's allocator assumptions do not hold.
- **Profiles at comptime, not runtime.** Absent code cannot be exploited.
- **Arena over general-purpose allocation.** Reset per turn, no fragmentation, bounded
  memory.
- **vtable transports.** One agent loop, swappable link layer.

## Testing

```bash
zig build test                    # 126 inline unit tests
bash test/integration.sh          # integration tests
bash test/smoke-test.sh           # smoke tests
```

Coverage is concentrated in `sensor.zig` (14), `json.zig` (12), `tools.zig` and `swarm.zig`
(11 each), and `cron.zig` (10). `main.zig`, `config.zig`, `api.zig`, `types.zig`, `ble.zig`,
`serial.zig`, `react.zig`, `tools_robotics.zig` and `api_ble.zig` have **no inline tests**.

The macOS run recorded in `Docs/CROSS-CHECK-RESULTS.md` reports "39+ tests PASS", predating
later test additions.

There is no CI. If you change something, run the tests yourself.

## Building

```bash
zig build                              # Debug
zig build -Doptimize=ReleaseSmall      # Smallest binary
zig build -Doptimize=ReleaseFast       # Fastest binary
zig build test                         # Run all tests
zig build size                         # ls -la on the built artifact

zig build -Dprofile=iot                # Tool profile
zig build -Dble=true                   # BLE transport
zig build -Dserial=true                # Serial transport
zig build -Dembedded=true              # Bare-metal
zig build -Dsandbox=true               # Sandbox mode
```

## Security

NanoAgent executes tools with the permissions of the running user. **Do not run it with
elevated privileges.**

- **Profile isolation** — IoT and robotics builds contain no `bash` tool
- **Sandbox mode** — restricts filesystem to `/tmp/nanoagent-sandbox`, empties `PATH`
- **Path allowlisting** — file tools restricted to cwd + `/tmp/nanoagent-*`
- **GPIO pin allowlist** — hardware tools only touch pre-approved pins
- **Rate limiting** — GPIO writes capped at 10/sec per pin (`bridge/hardware.py`), IoT
  bridge calls at 30/min (`tools_iot.zig`)
- **Shell quoting** — subprocess arguments are escaped
- **Loop detection** — caps runaway tool execution

BLE and Serial transports have **no encryption or authentication**. There is no CI running
these checks, and this code has not had a security review. Treat it as experimental.

See [SECURITY.md](SECURITY.md) for reporting vulnerabilities.

## Known Limitations

- **No CI.** No automated build, test or size checking of any kind.
- **No hardware validation.** MCU targets compile to stubs; none has been flashed.
- **No performance measurements.** Boot time, idle RAM and throughput are unmeasured.
- **JSON key search is flat.** Finds the first matching key outside string values, without
  tracking nesting depth. Fine for LLM API responses with unambiguous keys.
- **Token estimation is heuristic** — roughly 4 chars/token, not billing-precise.
- **Session persistence is bridge-mediated**, not native to the Zig binary.
- **BLE transport is protocol-only** — framing and simulation; real hardware needs a
  platform BLE SDK.
- **Serial baud configuration uses `stty`** — Linux/macOS only.
- **Requires Zig 0.15+** — uses the recent allocator vtable API.
- **Nine source files have no inline tests** (listed under Testing).
- **Naming is inconsistent.** The project was renamed from KrillClaw; `build.zig.zon` still
  declares `.name = .krillclaw`, and `Docs/`, `CONTRIBUTING.md`, the test scripts and the
  issue templates still say KrillClaw throughout. The built executable is `nanoagent`.

## Upstream and Licensing

This repository is a rename of **KrillClaw**. That upstream identity is still visible in
`build.zig.zon`, the docs and the test scripts, and it is the name the LICENSE grants rights
to.

- **Licensed Work:** KrillClaw, © 2026 **Accelerando AI**
- **Licensor:** Accelerando AI — commercial licensing: `hello@krillclaw.com`
- **License:** [Business Source License 1.1](LICENSE) — **source-available, not open source**
- **Additional Use Grant:** any purpose, including production, if your organisation has under
  $1,000,000 USD annual revenue **or** fewer than 10,000 deployed devices. Non-commercial,
  internal evaluation, academic and personal use are always permitted.
- **Change Date:** 17 February 2029 → converts to **Apache License 2.0**

The Business Source License text is copyright © 2017 **MariaDB Corporation Ab**. "Business
Source License" is a trademark of MariaDB Corporation Ab.

Commercial use above those thresholds requires a separate license from Accelerando AI.

## Contributing

Contributions welcome under BSL 1.1. See [CONTRIBUTING.md](CONTRIBUTING.md).

---

<p align="center">
  <sub>Built with Zig.</sub>
</p>
