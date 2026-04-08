# Contributing to KrillClaw

Thanks for your interest in KrillClaw! This document covers everything you need to get started.

## Quick Links

- [Issues](https://github.com/krillclaw/KrillClaw/issues) — Bug reports and feature requests
- [Discussions](https://github.com/krillclaw/KrillClaw/discussions) — Questions and ideas
- [Security Policy](SECURITY.md) — Reporting vulnerabilities

## License

KrillClaw is licensed under **BSL 1.1** (Business Source License). By contributing, you agree that your contributions will be licensed under the same terms. This is a source-available license, not an open source license. See [LICENSE](LICENSE) for details.

## Development Setup

### Prerequisites

- [Zig 0.13+](https://ziglang.org/download/)
- Git
- That's it. Zero other dependencies.

### Build & Test

```bash
git clone https://github.com/krillclaw/KrillClaw.git
cd KrillClaw

# Build
zig build                              # Debug
zig build -Doptimize=ReleaseSmall      # Release

# Test
zig build test                         # 39 unit tests
bash test/integration.sh               # 9 integration tests

# Check binary size (must stay under 300KB)
ls -la zig-out/bin/krillclaw
```

## What to Work On

### Good First Issues

Look for issues labeled [`good first issue`](https://github.com/krillclaw/KrillClaw/labels/good%20first%20issue). These are scoped, well-defined, and have context.

### Areas We Need Help

- **Transport testing** — BLE and Serial on real hardware
- **Platform support** — testing on new microcontroller targets
- **Documentation** — examples, tutorials, hardware guides
- **Tools** — new tool implementations for IoT and robotics profiles
- **Performance** — binary size and memory usage optimization

### What We Probably Won't Merge

- External Zig dependencies (zero-dep policy is core to the project)
- Regex support in search (intentional design decision — see README)
- Conversation persistence (may revisit, but not a priority)
- Support for languages other than Zig in the core runtime

## Making Changes

### Workflow

1. **Fork** the repo and create a branch from `main`
2. **Make changes** — keep them focused. One PR per concern.
3. **Add tests** for new functionality (inline Zig tests preferred)
4. **Run the full test suite** — `zig build test && bash test/integration.sh`
5. **Check binary size** — `zig build -Doptimize=ReleaseSmall && ls -la zig-out/bin/krillclaw`
6. **Open a PR** using the [template](.github/PULL_REQUEST_TEMPLATE.md)

### Code Style

- Follow standard Zig conventions
- Keep functions small and focused (<50 lines preferred)
- Use `comptime` for profile selection, not runtime branching
- Inline tests in each source file (next to the code they test)
- No allocations in hot paths when possible

### Binary Size Budget

KrillClaw has a hard CI gate: **the release binary must stay under 300KB**. Every line of code and every feature has a size cost. Before submitting:

```bash
zig build -Doptimize=ReleaseSmall
ls -la zig-out/bin/krillclaw
# Must be < 300KB
```

If your change increases binary size, explain why it's worth it in the PR.

### Commit Messages

Use clear, descriptive commit messages:

```
feat: add MQTT QoS 1 support to IoT profile
fix: SSE parser handles empty data fields
docs: add nRF5340 hardware guide
test: add context truncation edge cases
```

## Reporting Bugs

Use the [bug report template](https://github.com/krillclaw/KrillClaw/issues/new?template=bug_report.md). Include:

- Zig version (`zig version`)
- Build profile and flags
- Target platform/hardware
- Minimal reproduction steps

## Requesting Features

Use the [feature request template](https://github.com/krillclaw/KrillClaw/issues/new?template=feature_request.md). Consider:

- Does this fit the "smallest agent runtime" philosophy?
- What's the binary size impact?
- Does it require external dependencies? (If yes, it's likely a no.)

## Security Issues

**Do not open public issues for security vulnerabilities.** See [SECURITY.md](SECURITY.md) for responsible disclosure instructions.

## Questions?

Open a [Discussion](https://github.com/krillclaw/KrillClaw/discussions) thread. We're happy to help.
