## What

Brief description of changes.

## Why

What problem does this solve?

## How

Implementation approach — key decisions and trade-offs.

## Checklist

- [ ] `zig build test` passes (39 unit tests)
- [ ] `bash test/integration.sh` passes (9 integration tests)
- [ ] Release binary < 300KB (`zig build -Doptimize=ReleaseSmall && ls -la zig-out/bin/krillclaw`)
- [ ] No new external dependencies added
- [ ] Inline tests added for new functionality
- [ ] Documentation updated (README, code comments)

## Binary Size

| | Before | After | Delta |
|---|--------|-------|-------|
| **ReleaseSmall** | KB | KB | KB |

## Profile Impact

- [ ] Core (affects all profiles)
- [ ] Coding only
- [ ] IoT only
- [ ] Robotics only

## Testing

Describe how you tested these changes. Include hardware details if applicable.
