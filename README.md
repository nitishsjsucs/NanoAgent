<h1 align="center">
  <br>
  NanoAgent
  <br>
</h1>

<p align="center">
  <strong>The world's smallest autonomous AI agent runtime.</strong><br>
  <em>~450 KB binary. Zero dependencies. From microcontrollers to cloud servers.</em>
</p>

<p align="center">
  <a href="LICENSE"><img src="https://img.shields.io/badge/license-BSL_1.1-blue?style=flat-square" alt="License: BSL 1.1"></a>
  <img src="https://img.shields.io/badge/language-Zig_0.15+-f7a41d?style=flat-square&logo=zig&logoColor=white" alt="Zig 0.15+">
  <img src="https://img.shields.io/badge/binary-~450KB-00ff88?style=flat-square" alt="Binary size">
  <img src="https://img.shields.io/badge/dependencies-0-brightgreen?style=flat-square" alt="Zero deps">
  <img src="https://img.shields.io/badge/tests-60+-blue?style=flat-square" alt="Tests">
</p>

<p align="center">
  <a href="#quick-start">Quick Start</a> &middot;
  <a href="#why-nanoagent">Why NanoAgent?</a> &middot;
  <a href="#architecture">Architecture</a> &middot;
  <a href="#profiles">Profiles</a> &middot;
  <a href="#embedded-mode">Embedded</a> &middot;
  <a href="#configuration-reference">Config</a> &middot;
  <a href="CONTRIBUTING.md">Contributing</a>
</p>

---

NanoAgent is an autonomous AI agent runtime written from scratch in **Zig** — no standard library JSON, no external packages, no runtime dependencies. It implements a full **ReAct (Reason + Act) agent loop** that connects to 20+ LLM providers, executes tools, manages context windows, streams responses, and loops until the task is done.

The entire runtime — LLM client, tool executor, JSON parser, SSE streaming, cron scheduler, KV store, context manager, and three transport layers — compiles to a **single static binary under 450 KB** with link-time optimization. It boots in under 10 ms, runs on 2 MB of RAM, and targets everything from a **$3 ESP32** to a cloud VM.

```
 ┌─────────────────────────────────────────────────────────────┐
 │                                                             │
 │   ~450 KB binary.  Zero dependencies.  Boots in <10 ms.    │
 │                                                             │
 │   19 source files  ·  4,576 lines of Zig  ·  60+ tests     │
 │   3 compile-time profiles  ·  3 transport layers            │
 │   7 messaging channels  ·  20+ LLM providers                │
 │                                                             │
 └─────────────────────────────────────────────────────────────┘
```

## Table of Contents

- [Quick Start](#quick-start)
- [Why NanoAgent?](#why-nanoagent)
- [Architecture](#architecture)
- [Profiles](#profiles)
- [Providers](#providers)
- [Embedded Mode](#embedded-mode)
- [Transport Layers](#transport-layers)
- [Cron / Daemon Mode](#cron--heartbeat-daemon-mode)
- [Messaging Channels](#messaging-channels)
- [MCP Support](#mcp-support)
- [GPIO / Hardware Control](#gpio--hardware-control)
- [Plugins](#skills--plugins)
- [Configuration Reference](#configuration-reference)
- [Design Decisions](#design-decisions)
- [Testing](#testing)
- [Building](#building)
- [Security](#security)
- [Known Limitations](#known-limitations)
- [License](#license)
- [Contributing](#contributing)

## Quick Start

```bash
# 1. Install Zig 0.15+ (https://ziglang.org/download/)

# 2. Clone and build — takes about 1 second
git clone https://github.com/nanoagent/NanoAgent.git
cd NanoAgent
zig build -Doptimize=ReleaseSmall

# 3. Set your API key
export ANTHROPIC_API_KEY=sk-ant-...

# 4. One-shot mode — run a single task and exit
./zig-out/bin/nanoagent "create a REST API in Go with user auth"

# 5. Interactive REPL — conversational coding session
./zig-out/bin/nanoagent
```

No npm. No pip. No Docker. No virtualenv. One binary, zero setup.

## Why NanoAgent?

Every AI agent runtime today is massive. Desktop coding agents ship as **50–500 MB** bundles with hundreds of transitive dependencies. The core logic — *call LLM, parse response, execute tools, repeat* — is fundamentally simple. It shouldn't require Node.js, Python, or a container runtime.

NanoAgent proves it doesn't. The same agentic loop that powers desktop tools, compiled to a binary **smaller than a JPEG**, running on hardware that **costs less than a coffee**.

> **NanoAgent exists because AI agents should run everywhere** — not just on machines with 8 GB of RAM and a package manager.

### How It Compares

| Metric | NanoAgent | Typical Edge Runtime | Desktop Agent |
|---|:---:|:---:|:---:|
| **Binary size** | **~450 KB** | 2–8 MB | 50–500 MB |
| **RAM at idle** | **~2 MB** | 10–512 MB | 150 MB – 1 GB |
| **Source lines** | **4,576** | 5–30K | 30–100K+ |
| **Dependencies** | **0** | 10–100+ | 100–1000+ |
| **Cold-start time** | **< 10 ms** | < 1 s | 2–5 s |
| **Embedded / BLE** | **Yes** | Sometimes | No |
| **Cron / Daemon** | **Yes** | Sometimes | No |
| **LLM providers** | **20+** | 1–3 | 1–5 |

### Feature Matrix

| Capability | NanoAgent | Details |
|-----------|:---------:|---------|
| ReAct agent loop | **Yes** | Think → Act → Observe with hard iteration cap |
| SSE streaming | **Yes** | Real-time token display, zero-allocation event type parsing |
| Multi-provider LLM | **20+** | Claude, OpenAI, Ollama + any OpenAI-compatible API via `--base-url` |
| Compile-time profiles | **3** | `coding`, `iot`, `robotics` — dead code eliminated at compile time |
| Transport layers | **3** | HTTP, BLE GATT, Serial/UART |
| Messaging channels | **7** | Telegram, Discord, Slack, WhatsApp, MQTT, WebSocket, Webhook |
| Context management | **Yes** | Priority-based truncation with O(n) cached token tracking |
| Loop detection | **Yes** | FNV-1a hashing in constant memory (128 bytes) |
| Persistent KV store | **Yes** | File-backed key-value store available to all profiles |
| MCP support | **Yes** | Model Context Protocol client bridge — 1000+ external tools |
| GPIO / Hardware | **Yes** | GPIO, I2C, SPI via bridge with pin allowlist and rate limiting |
| Sandbox mode | **Yes** | Restricted filesystem + empty PATH for safe execution |
| Plugin system | **Yes** | Drop-in Python tools in `~/.nanoagent/plugins/` |
| Fixed arena allocator | **Yes** | Last-alloc resize optimization for embedded targets |
| LTO | **Yes** | Link-time optimization for ReleaseSmall / ReleaseFast builds |
| Inline tests | **60+** | JSON, SSE, arena, context, tools, glob, security injection |

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
│                 └──┬────┬──┬──┘                                  │
│                    │    │  │                                      │
│                ┌───▼┐ ┌▼──┴──┐                                   │
│                │HTTP│ │BLE   │ │Serial│                           │
│                └────┘ └──────┘ └──────┘                           │
│                                                                  │
│  Core:    json.zig · stream.zig · context.zig · react.zig       │
│  Infra:   config.zig · types.zig · arena.zig · cron.zig         │
│  Edge:    ble.zig · serial.zig · transport.zig · fault_log.zig  │
└──────────────────────────────────────────────────────────────────┘

  19 source files  ·  4,576 lines  ·  0 dependencies  ·  60+ tests
```

### Source Map

| File | LOC | Purpose |
|------|----:|---------|
| `main.zig` | 314 | Entry point: CLI arg parsing, REPL, cron daemon, embedded mode |
| `agent.zig` | 317 | Agent loop: LLM calls, tool dispatch, streaming, error recovery |
| `react.zig` | 105 | ReAct orchestration: classify → extract thought → execute tools |
| `api.zig` | 171 | Multi-provider HTTP client with streaming support |
| `stream.zig` | 380 | SSE parser with zero-allocation event type enum dispatch |
| `json.zig` | 540 | Hand-rolled JSON builder + extractor with string-aware key search |
| `context.zig` | 230 | Token estimation + O(n) priority-based context truncation |
| `tools.zig` | 206 | Tool dispatcher: shared → profile → bridge fallback chain |
| `tools_shared.zig` | 362 | Cross-profile tools: time, KV store, web search, sessions, OTA |
| `tools_coding.zig` | 484 | Coding: bash, read/write/edit, search, list, patch, glob |
| `tools_iot.zig` | 176 | IoT: MQTT, HTTP, GPIO bridge, device info |
| `tools_robotics.zig` | 153 | Robotics: motion commands, e-stop, telemetry |
| `config.zig` | 203 | Config loading: file → env → CLI precedence chain |
| `types.zig` | 159 | Core types: Provider, Message, Config, ToolDef, ContentBlock |
| `transport.zig` | 179 | Abstract vtable transport + BLE/Serial RPC protocol |
| `ble.zig` | 159 | BLE GATT transport (Nordic SoftDevice integration points) |
| `serial.zig` | 142 | UART transport with length-prefixed framing |
| `arena.zig` | 210 | Fixed arena allocator with last-alloc resize optimization |
| `cron.zig` | 206 | Interval scheduler for daemon mode (no threads, ~2 KB cost) |

## Profiles

Compile-time profiles select different tool sets via Zig's `comptime` evaluation. Only the selected profile's code is included in the final binary — everything else is dead-code eliminated. This means the IoT binary has **zero coding tools** and the coding binary has **zero MQTT code**.

```bash
# Coding agent (default) — bash, file I/O, search, patch
zig build -Dprofile=coding -Doptimize=ReleaseSmall

# IoT agent — MQTT, HTTP, GPIO bridge, device info
zig build -Dprofile=iot -Doptimize=ReleaseSmall

# Robotics agent — motion commands, e-stop, telemetry
zig build -Dprofile=robotics -Doptimize=ReleaseSmall
```

| Profile | Included Tools | Binary Size | Security Model |
|---------|---------------|:-----------:|----------------|
| **coding** | `bash`, `read_file`, `write_file`, `edit_file`, `search`, `list_files`, `patch` + shared | ~459 KB | Writes restricted to cwd + `/tmp/nanoagent-*`; sandbox mode available |
| **iot** | `mqtt_publish`, `mqtt_subscribe`, `http_request`, `gpio_*`, `device_info` + shared | ~463 KB | No bash, no file writes, 30 req/min rate limit |
| **robotics** | `robot_cmd`, `estop`, `telemetry` + shared | ~473 KB | No bash, bounds checking, 10 cmd/s, hardware e-stop |

**Shared tools** (available in every profile):
- `get_current_time` — ISO-8601 UTC timestamp
- `kv_get` / `kv_set` / `kv_list` / `kv_delete` — persistent file-backed key-value store
- `web_search` — DuckDuckGo search (no API key needed)
- `session_save` / `session_load` / `session_list` — conversation persistence
- `ota_check` / `ota_download` / `ota_apply` — over-the-air binary updates from GitHub

All profiles support **sandbox mode**: `zig build -Dsandbox=true` — restricts all file operations to `/tmp/nanoagent-sandbox` and empties `PATH`.

## Providers

NanoAgent supports **20+ LLM providers** through three protocol backends. Any provider with an OpenAI-compatible chat completions API works out of the box via `--base-url`.

| Backend | Provider | Default Model | Auth |
|---------|----------|---------------|------|
| **Claude** | Anthropic | `claude-sonnet-4-5-20250929` | `ANTHROPIC_API_KEY` |
| **OpenAI** | OpenAI | `gpt-4o` | `OPENAI_API_KEY` |
| **Ollama** | Local | `llama3` | None |
| **OpenAI-compat** | Groq, DeepSeek, Together, Fireworks, Mistral, Google Gemini, Perplexity, Cerebras, Lambda, Anyscale, OpenRouter, vLLM, LiteLLM, Azure OpenAI, AWS Bedrock, Cloudflare Workers AI, etc. | Varies | `--base-url` + provider key |

```bash
# Claude (default)
./zig-out/bin/nanoagent "fix the tests"

# OpenAI
export OPENAI_API_KEY=sk-...
./zig-out/bin/nanoagent --provider openai -m gpt-4o "fix the tests"

# Local Ollama (no API key, no internet)
./zig-out/bin/nanoagent --provider ollama -m llama3 "explain this code"

# Groq (ultra-fast inference)
OPENAI_API_KEY=gsk_... ./zig-out/bin/nanoagent \
  --provider openai --base-url https://api.groq.com/openai \
  -m llama-3.3-70b-versatile "optimize this function"

# DeepSeek
OPENAI_API_KEY=sk-... ./zig-out/bin/nanoagent \
  --provider openai --base-url https://api.deepseek.com \
  -m deepseek-chat "refactor this module"

# Google Gemini (via OpenAI compatibility layer)
OPENAI_API_KEY=... ./zig-out/bin/nanoagent \
  --provider openai \
  --base-url https://generativelanguage.googleapis.com/v1beta/openai \
  -m gemini-2.0-flash "summarize this repo"
```

## Embedded Mode

NanoAgent's primary design target is **microcontrollers and edge devices**. The device runs the agent brain (ReAct loop, JSON parsing, state management). A phone or laptop bridges network requests and tool execution.

```
┌──────────────┐       BLE / UART       ┌───────────────┐      HTTPS      ┌─────────┐
│  NanoAgent   │ ◄─────────────────────► │    Bridge      │ ◄────────────► │  LLM    │
│  (device)    │                         │  (phone/PC)    │                │  API    │
│              │  {"type":"tool",...}     │                │                └─────────┘
│  Agent loop  │ ──────────────────────► │ Execute tools  │
│  JSON parse  │                         │ Forward to API │
│  State mgmt  │ ◄────────────────────  │ Return result  │
│   ~50 KB     │  {"type":"result",...}  │  bridge.py     │
└──────────────┘                         └────────────────┘
```

### Build for Hardware

```bash
# BLE transport (Nordic nRF52840, nRF5340)
zig build -Dble=true -Doptimize=ReleaseSmall

# Serial/UART transport (ESP32, Raspberry Pi Pico, any UART device)
zig build -Dserial=true -Doptimize=ReleaseSmall

# Full embedded mode (bare-metal, no OS)
zig build -Dembedded=true -Dtarget=thumb-none-eabi -Doptimize=ReleaseSmall
```

### Target Hardware

| Device | SoC | RAM | Flash | Cost | Transport |
|--------|-----|-----|-------|-----:|-----------|
| **ESP32-C3** | RISC-V | 400 KB | 4 MB | $3 | Serial |
| **Raspberry Pi Pico W** | RP2040 | 264 KB | 2 MB | $6 | Serial |
| **Colmi R02** (smart ring) | BlueX RF03 | ~32 KB | ~256 KB | $20 | BLE |
| **nRF52840-DK** | nRF52840 | 256 KB | 1 MB | $40 | BLE |
| **nRF5340-DK** | nRF5340 | 512 KB | 1 MB | $50 | BLE |

### Fixed Arena Allocator

For devices with no OS heap, NanoAgent provides a fixed-size arena allocator with a **last-allocation resize optimization** — when the most recent allocation is grown (common with `ArrayList`), it extends in-place without copying:

```zig
var mem = arena.Arena32K.init();  // 32 KB — fits on nRF5340
const alloc = mem.allocator();
// ... use alloc for all agent operations ...
mem.reset();  // Free everything at once between agent turns
```

Preset sizes: `Arena4K` (Colmi R02), `Arena16K` (nRF52840), `Arena32K` (nRF5340), `Arena128K` (Balletto B1), `Arena256K` (desktop-embedded hybrid).

## Transport Layers

| Transport | Use Case | Protocol | Status |
|-----------|----------|----------|--------|
| **HTTP** | Desktop / cloud — direct HTTPS to LLM API | Standard HTTP/1.1 | Stable |
| **BLE** | Embedded — GATT service with MTU framing | Custom GATT (0xPC01–0xPC03) | Experimental |
| **Serial** | Dev boards — UART to host machine | Length-prefixed JSON lines | Experimental |

All transports implement the same vtable interface. The agent logic is **transport-agnostic** — swap the physical layer without touching a single line of agent code.

> **BLE note:** Desktop simulation uses Unix sockets (`/tmp/nanoagent.sock`). Real hardware requires linking against the platform BLE SDK (e.g., Nordic SoftDevice). See `ble.zig` for integration points.

## Cron / Heartbeat (Daemon Mode)

Run NanoAgent as a scheduled agent on edge devices:

```bash
# Run agent every 5 minutes with a custom prompt
nanoagent --cron-interval 300 --cron-prompt "check sensors and report anomalies"

# Heartbeat logging every 60 seconds + agent every 10 minutes
nanoagent --heartbeat 60 --cron-interval 600

# Run exactly 10 times then exit
nanoagent --cron-interval 120 --cron-max-runs 10 --cron-prompt "collect data"
```

The scheduler adds ~2 KB to binary size, uses no threads, and is designed for edge devices running periodic data collection between connectivity windows.

## Messaging Channels

7 messaging channels let your agent communicate wherever your users are:

| Channel | Library | Auth | Use Case |
|---------|---------|------|----------|
| **Telegram** | stdlib `urllib` | Bot token | Chat-based interaction |
| **Discord** | `discord.py` | Bot token | Team / community agents |
| **Slack** | `slack-bolt` | Bot + App token (Socket Mode) | Workspace automation |
| **WhatsApp** | Cloud API (Meta) | Business access token | Customer-facing agents |
| **MQTT** | `paho-mqtt` | Broker config | IoT device messaging |
| **WebSocket** | `websockets` | Token auth | Browser clients, streaming |
| **Webhook** | stdlib `http.server` | Bearer token | Simplest HTTP integration |

```bash
# Start multi-channel server
python bridge/bridge/bridge.py --serve --channels telegram,discord,webhook

# WebSocket gateway for browser clients
python bridge/bridge/bridge.py --serve --channels websocket
```

### Channel Configuration

Per-channel settings via `~/.nanoagent/channels.json`:

```json
{
  "webhook": {"port": 8080, "auth_token": "secret"},
  "websocket": {"port": 8765, "agent_binary": "./zig-out/bin/nanoagent"},
  "telegram": {"token": "bot123:ABC", "allowed_users": [12345]},
  "mqtt": {"broker": "localhost", "subscribe_topic": "nanoagent/in"}
}
```

### WebSocket Wire Protocol

```json
→ {"type": "message", "text": "fix the bug"}
← {"type": "text", "text": "Let me look at that..."}
← {"type": "done"}
```

## MCP Support

NanoAgent integrates with [Model Context Protocol](https://modelcontextprotocol.io/) (MCP) servers, connecting your agent to **1000+ external tools** from the MCP ecosystem.

```json
// ~/.nanoagent/mcp_servers.json
{
  "mcpServers": {
    "filesystem": {
      "command": "npx",
      "args": ["-y", "@modelcontextprotocol/server-filesystem", "/home/user"]
    },
    "remote": {
      "transport": "http",
      "url": "https://my-server.com/mcp"
    }
  }
}
```

```bash
# Start with MCP tools available
python bridge/bridge/bridge.py --serve --channels webhook
```

MCP tools are auto-discovered and namespaced as `servername__toolname`. Supports both **stdio** and **streamable HTTP** transports.

## GPIO / Hardware Control

Direct hardware control from AI — GPIO, I2C, SPI — with safety guardrails:

| Tool | Description | Safety |
|------|-------------|--------|
| `gpio_read` | Read a GPIO pin value | Pin allowlist |
| `gpio_write` | Write a value to a GPIO pin | Pin allowlist + rate limiting |
| `gpio_list` | List available GPIO pins | — |
| `i2c_read` | Read from an I2C device | Address allowlist |
| `spi_transfer` | Transfer data over SPI | Device allowlist |

```bash
# Build with IoT profile
zig build -Dprofile=iot -Doptimize=ReleaseSmall

# GPIO tools route through the Python bridge
# Linux: real hardware via libgpiod
# macOS/Windows: simulator mode (logs commands)
```

Safety configuration via `~/.nanoagent/hardware.json`:
```json
{
  "allowed_pins": [17, 18, 27, 22],
  "gpio_chip": "gpiochip0"
}
```

## Skills / Plugins

Extend NanoAgent with custom Python tools. Drop a `.py` file in `~/.nanoagent/plugins/`:

```python
# ~/.nanoagent/plugins/my_tool.py
TOOL_NAME = "my_custom_tool"
TOOL_DESCRIPTION = "Does something custom."
TOOL_SCHEMA = {"type": "object", "properties": {"input": {"type": "string"}}}

def handle(data: dict) -> dict:
    return {"result": f"processed: {data.get('input', '')}"}
```

Plugins are discovered on bridge startup. Unknown tools from the Zig agent automatically fall through to the bridge, which routes them to the matching plugin handler. Built-in tool names cannot be overridden (security invariant).

## Configuration Reference

### Precedence

**CLI flags → Environment variables → Config file → Defaults**

### Environment Variables

| Variable | Description | Default |
|----------|-------------|---------|
| `ANTHROPIC_API_KEY` | Claude API key | — |
| `OPENAI_API_KEY` | OpenAI API key (auto-selects `openai` provider) | — |
| `NANOAGENT_MODEL` | Model name override | `claude-sonnet-4-5-20250929` |
| `NANOAGENT_PROVIDER` | Provider override (`claude`, `openai`, `ollama`) | `claude` |
| `NANOAGENT_BASE_URL` | Custom API base URL | Provider default |
| `NANOAGENT_SYSTEM_PROMPT` | System prompt override | Built-in |
| `NANOAGENT_MAX_TOKENS` | Max response tokens | `8192` |
| `NANOAGENT_TRANSPORT` | Transport layer (`http`, `ble`, `serial`) | `http` |
| `NANOAGENT_SERIAL_PORT` | Serial port path | — |
| `NANOAGENT_BLE_DEVICE` | BLE device address | — |

### Config File

Project-level configuration via `.nanoagent.json`:

```json
{
  "model": "claude-sonnet-4-5-20250929",
  "provider": "claude",
  "max_tokens": 8192,
  "max_turns": 50,
  "streaming": true,
  "system_prompt": "You are a Go expert...",
  "base_url": "https://my-proxy.com"
}
```

### CLI Flags

```
nanoagent [OPTIONS] [PROMPT]

Options:
  -m, --model MODEL        Model name
  -p, --prompt TEXT         Run a single prompt and exit
  --provider PROVIDER       claude | openai | ollama
  --base-url URL            Custom API base URL
  --no-stream               Disable streaming
  --transport TYPE          http | ble | serial
  --serial-port PATH        Serial port (e.g. /dev/ttyUSB0)
  --ble-device ADDR         BLE device address
  --cron-interval SECS      Run agent every N seconds (daemon mode)
  --cron-prompt TEXT         Prompt for cron runs
  --cron-max-runs N          Stop after N cron runs (0 = unlimited)
  --heartbeat SECS          Log heartbeat every N seconds
  -v, --version             Show version
  -h, --help                Show help
```

### REPL Commands

| Command | Description |
|---------|-------------|
| `/help` | Show available commands |
| `/quit` `/exit` `/q` | Exit the REPL |
| `/model <name>` | Switch LLM model |
| `/provider <name>` | Switch LLM provider |

## Design Decisions

| Decision | Rationale |
|----------|-----------|
| **Hand-rolled JSON** | `std.json` pulls in unnecessary code. NanoAgent only needs key extraction + request body building. ~540 lines with string-aware key search, zero deps. |
| **Zero-alloc SSE event types** | SSE event types (`message_start`, `content_block_delta`, etc.) are parsed into an enum instead of heap-allocated strings — eliminates 2 allocations per event. |
| **O(n) context truncation** | Token totals are computed once and decremented incrementally as messages are removed, avoiding the O(n²) cost of recalculating on every removal. |
| **Last-alloc arena resize** | The fixed arena allocator tracks the most recent allocation offset, allowing `ArrayList` growth to extend in-place without copying — the most common allocation pattern. |
| **LTO for release builds** | Link-time optimization enables cross-module inlining and dead code elimination, reducing binary size beyond what Zig's comptime can achieve alone. |
| **Vtable transports** | Same binary works over HTTP, BLE, or Serial. Swap physical layer without touching agent logic. |
| **FNV-1a loop detection** | Detect stuck LLM loops using a ring buffer of hashes in constant memory (128 bytes). Critical for unattended embedded operation. |
| **Priority-based truncation** | When context fills, drop assistant text first, then user text, keep tool results last. Preserves working memory at the expense of chat history. |
| **Substring search, not regex** | Regex engines are 10K+ lines. `std.mem.indexOf` covers 90%+ of agent search use cases in a fraction of the code. |
| **Comptime profile selection** | `@import` at compile time means unused profiles contribute exactly 0 bytes to the binary. No feature flags at runtime. |

## Testing

```bash
zig build test                    # 60+ inline unit tests
bash test/integration.sh          # Integration tests
```

Test coverage includes:
- **JSON** — key extraction, string escaping/unescaping, nested objects, arrays, builder output
- **SSE streaming** — text-only, tool use, token counts, callback firing, chunked feed (byte-at-a-time)
- **Arena** — basic alloc, overflow, alignment, peak tracking, multiple allocations, integer overflow safety, preset sizes
- **Context** — token estimation, message token estimation, near-limit detection, usage string formatting
- **Tools** — bash exec, file read/write/edit, glob matching, command injection prevention
- **Security** — shell injection via search, injection via list_files, path traversal guards

CI runs on every push with a **binary size gate** (< 600 KB).

## Building

```bash
zig build                              # Debug build
zig build -Doptimize=ReleaseSmall      # Smallest binary (LTO enabled)
zig build -Doptimize=ReleaseFast       # Fastest binary (LTO enabled)
zig build test                         # Run all tests
zig build size                         # Report binary size

# Build flags
zig build -Dprofile=iot                # Select tool profile
zig build -Dble=true                   # Enable BLE transport
zig build -Dserial=true                # Enable serial transport
zig build -Dembedded=true              # Bare-metal embedded mode
zig build -Dsandbox=true               # Sandbox mode
```

## Security

NanoAgent executes tools with the permissions of the running user. **Do not run with elevated privileges.**

### Mitigations

- **Profile isolation** — IoT and robotics profiles have no `bash` tool at all
- **Sandbox mode** — restricts filesystem to `/tmp/nanoagent-sandbox`, empties `PATH`
- **Path allowlisting** — file tools restricted to cwd + `/tmp/nanoagent-*` (coding profile)
- **GPIO pin allowlist** — hardware tools only operate on pre-approved pins
- **Rate limiting** — GPIO writes (10/sec), HTTP requests (30/min in IoT)
- **Shell quoting** — all subprocess arguments are properly escaped
- **Loop detection** — prevents runaway tool execution on stuck LLM outputs

BLE and Serial transports do **not** currently include encryption or authentication. Use only on trusted networks.

See [SECURITY.md](SECURITY.md) for reporting vulnerabilities.

## Known Limitations

- **JSON key search is string-aware but flat** — finds the first matching key outside of string values, but does not track object nesting depth. Works correctly for LLM API responses where keys are unambiguous across nesting levels.
- **Token estimation is heuristic** — uses ~4 chars/token approximation. Accurate enough for context management but not billing-precise.
- **Session persistence is bridge-mediated** — save/load via bridge tools, not native to the Zig binary.
- **BLE transport is protocol-only** — implements framing and simulation; real hardware requires platform BLE SDK linking (e.g., Nordic SoftDevice).
- **Serial baud configuration uses `stty`** — Linux/macOS only.
- **Requires Zig 0.15+** — uses recent allocator vtable API.

## My Contributions

- **ReAct Agent Loop** — Designed and implemented the core Reason-Act-Observe agent loop in Zig with streaming JSON parsing, tool dispatch, and configurable iteration limits.
- **Multi-Transport Layer** — Built the pluggable transport architecture supporting HTTP, BLE (with MTU-aware framing), and Serial (UART) communication for edge deployment.
- **LLM Provider Abstraction** — Created the provider-agnostic LLM interface supporting OpenAI, Anthropic, Ollama, and LM Studio with automatic model detection and token estimation.
- **Plugin System** — Developed the dynamic plugin loading system with lifecycle hooks, capability declaration, and bridge-mediated tool registration.
- **Memory & Context Management** — Implemented the sliding-window context manager with token-budgeted message history and system prompt injection.

---

## License

[BSL 1.1](LICENSE) — Business Source License. Converts to **Apache 2.0** after 3 years (Change Date: 2029-02-17).

NanoAgent is **source-available**, not open source. You can read, build, and modify the code freely. Commercial use above the license thresholds requires a commercial license. See [LICENSE](LICENSE) for full terms.

## Contributing

Contributions welcome under BSL 1.1. See [CONTRIBUTING.md](CONTRIBUTING.md) for guidelines.

---

<p align="center">
  <sub>Built with Zig. Zero frameworks were harmed in the making of this runtime.</sub>
</p>
