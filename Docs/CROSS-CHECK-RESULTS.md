# Cross-Architecture Validation Results

**Date:** 2026-02-28 (updated)
**Zig Version:** 0.15.2
**Host:** macOS arm64 (Apple Silicon Mac Mini)
**Method:** Cross-compile with Zig, execute via Docker multiarch (QEMU user-mode)

> **Note:** Sizes below reflect Phase 2 additions (cron scheduler, shared tools, OTA update support, web search, session persistence).

## Execution Results

### Tier 1 — Linux (Executed via Docker Multiarch)

All configurations compile, link, and **execute successfully**, printing `krillclaw 0.1.0` and 33 lines of `--help` output (up from 29, reflecting new cron flags).

| Profile | Target | Platform | Binary Size | `--version` | `--help` |
|---------|--------|----------|:-----------:|:-----------:|:--------:|
| coding | aarch64-linux | linux/arm64 | 452KB | PASS | PASS (33 lines) |
| iot | aarch64-linux | linux/arm64 | 432KB | PASS | PASS |
| robotics | aarch64-linux | linux/arm64 | 450KB | PASS | PASS |
| coding | arm-linux | linux/arm/v7 | 547KB | PASS | PASS (33 lines) |
| iot | arm-linux | linux/arm/v7 | 525KB | PASS | PASS |
| robotics | arm-linux | linux/arm/v7 | 545KB | PASS | PASS |
| coding | riscv64-linux | linux/riscv64 | 588KB | PASS | PASS (33 lines) |
| iot | riscv64-linux | linux/riscv64 | 570KB | PASS | PASS |
| robotics | riscv64-linux | linux/riscv64 | 588KB | PASS | PASS |
| coding | x86_64-linux | linux/amd64 | 526KB | PASS | PASS (33 lines) |
| iot | x86_64-linux | linux/amd64 | 502KB | PASS | PASS |
| robotics | x86_64-linux | linux/amd64 | 520KB | PASS | PASS |
| coding | powerpc64le-linux | linux/ppc64le | 543KB | PASS | PASS (33 lines) |
| iot | powerpc64le-linux | linux/ppc64le | 519KB | PASS | PASS |
| robotics | powerpc64le-linux | linux/ppc64le | 539KB | PASS | PASS |
| coding | s390x-linux | linux/s390x | 677KB | PASS | PASS (33 lines) |
| iot | s390x-linux | linux/s390x | 648KB | PASS | PASS |
| robotics | s390x-linux | linux/s390x | 659KB | PASS | PASS |

**18 executed configurations** across 6 Linux architectures × 3 profiles.

### Tier 2 — Linux (Compile-Only, No Docker Image Available)

These cross-compile and link successfully but lack Docker base images for execution testing.

| Profile | Target | Binary Size | Compile | Link |
|---------|--------|:-----------:|:-------:|:----:|
| coding | mipsel-linux | 873KB | PASS | PASS |
| iot | mipsel-linux | 862KB | PASS | PASS |
| robotics | mipsel-linux | 887KB | PASS | PASS |
| coding | x86-linux (i386) | 607KB | PASS | PASS |
| iot | x86-linux (i386) | 598KB | PASS | PASS |
| robotics | x86-linux (i386) | 617KB | PASS | PASS |
| coding | loongarch64-linux | 694KB | PASS | PASS |
| iot | loongarch64-linux | 685KB | PASS | PASS |
| robotics | loongarch64-linux | 700KB | PASS | PASS |
| coding | mips64el-linux | 732KB | PASS | PASS |
| iot | mips64el-linux | 722KB | PASS | PASS |
| robotics | mips64el-linux | 741KB | PASS | PASS |

**12 compile-only configurations** across 4 additional Linux architectures × 3 profiles.

### macOS Native

| Profile | Target | Binary Size | `--version` | `--help` | Tests |
|---------|--------|:-----------:|:-----------:|:--------:|:-----:|
| coding | macOS arm64 | 508KB | PASS | PASS | 39+ tests PASS |

### Freestanding / Bare-Metal (Compile-Only)

These compile and produce valid ELF binaries. They are minimal stubs without a board-specific HAL — real execution requires HAL integration + emulator (Renode/QEMU system-mode).

#### Generic Freestanding

| Target | Size | ELF Type | Status |
|--------|------|----------|--------|
| arm-freestanding | 424B | ELF 32-bit ARM EABI5 | Compiles (needs HAL) |
| thumb-freestanding | 424B | ELF 32-bit ARM EABI5 | Compiles (needs HAL) |
| aarch64-freestanding | 472B | ELF 64-bit ARM aarch64 | Compiles (needs HAL) |
| riscv64-freestanding | 704B | ELF 64-bit RISC-V | Compiles (needs HAL) |
| riscv32-freestanding | 496B | ELF 32-bit RISC-V | Compiles (needs HAL) |

#### MCU-Specific Thumb Targets (Compile-Only)

All compile with `-Dprofile=iot -Dembedded=true`:

| CPU Target | Size | Maps To |
|-----------|------|---------|
| cortex_m0 | 432B | BBC micro:bit, nRF51822, STM32F0 |
| cortex_m0plus | 436B | RP2040 (Raspberry Pi Pico), SAMD21, STM32L0 |
| cortex_m3 | 432B | STM32F1/F2, LPC1768, LM3S6965 |
| cortex_m4 | 432B | nRF52840, nRF52832, STM32F4, STM32L4 |
| cortex_m7 | 432B | STM32F7, STM32H7, i.MX RT |
| cortex_m23 | 432B | STM32L5 (NS), LPC55S0x |
| cortex_m33 | 432B | nRF5340, nRF9160, STM32U5 |
| cortex_m55 | 436B | Corstone-300, Alif Ensemble (Helium/MVE) |

## Device Mapping

### Linux Targets (Executed)

| Architecture | Devices |
|-------------|---------|
| **aarch64-linux** | Raspberry Pi 4/5, Jetson Nano, Pine64, ODROID, Rock64, ARM64 SBCs |
| **arm-linux** (ARMv7) | Raspberry Pi Zero/2/3, BeagleBone, 32-bit ARM boards |
| **riscv64-linux** | Milk-V Duo/Mars, SiFive HiFive Unmatched, LicheeRV, StarFive VisionFive 2 |
| **x86_64-linux** | Old laptops, NAS boxes, Intel NUC, Mini PCs, thin clients |
| **powerpc64le-linux** | IBM POWER9 edge, Raptor Talos II, MPC8xxx routers |
| **s390x-linux** | IBM Z mainframes, LinuxONE (enterprise edge) |

### Linux Targets (Compile-Only)

| Architecture | Devices |
|-------------|---------|
| **mipsel-linux** | OpenWrt routers (TP-Link, Ubiquiti), Ingenic SoCs, Cavium |
| **x86-linux** (i386) | Legacy 32-bit PCs, thin clients, old embedded x86 |
| **loongarch64-linux** | Loongson 3A5000/3A6000, Chinese domestic SBCs |
| **mips64el-linux** | Loongson 2K/3A (older), Cavium Octeon routers |

### Freestanding / Bare-Metal

| Architecture | Devices |
|-------------|---------|
| **cortex_m0/m0+** | BBC micro:bit, RP2040 (Pi Pico), SAMD21, STM32F0/L0 |
| **cortex_m3** | STM32F1/F2, LPC1768, TI Stellaris |
| **cortex_m4** | nRF52840, nRF52832, STM32F4/L4, Adafruit Feather |
| **cortex_m7** | STM32F7/H7, i.MX RT1050/1060 |
| **cortex_m23/m33** | nRF5340, nRF9160 (cellular IoT), STM32L5/U5 (TrustZone) |
| **cortex_m55** | Corstone-300, Alif Ensemble (ML-capable MCUs) |
| **riscv32-freestanding** | ESP32-C3/C6/H2, GD32VF103, BL602 |
| **riscv64-freestanding** | SiFive FE310/FU540, LiteX SoC |
| **aarch64-freestanding** | Custom aarch64 bare-metal |

## Summary

| Category | Configurations | Level |
|----------|:--------------:|-------|
| Linux executed (Docker multiarch) | 18 | Compile + Link + Run `--version` + Run `--help` |
| Linux compile-only | 12 | Compile + Link (no Docker image available) |
| macOS native | 1 | Full test suite (39+ tests) |
| Freestanding generic | 5 | Compile + Link + ELF validation |
| Freestanding MCU-specific | 8 | Compile + Link (needs HAL for execution) |
| **Total** | **44** | |

### By Architecture (10 Linux + 13 bare-metal targets)

- **6 Linux architectures with execution proof**: aarch64, armv7, riscv64, x86_64, ppc64le, s390x
- **4 Linux architectures compile-only**: mipsel, x86 (i386), loongarch64, mips64el
- **13 bare-metal targets**: 8 Cortex-M variants + 2 ARM + 1 AArch64 + 2 RISC-V

## Test Infrastructure

- Docker with `tonistiigi/binfmt` for QEMU user-mode multiarch
- Colima as Docker runtime on macOS
- QEMU 10.2.1 system-mode installed (for future bare-metal board testing)
- Zig cross-compilation (no external toolchains needed)
- Renode available for download (bare-metal SoC emulation for nRF52840, STM32, SiFive)

### QEMU System-Mode Machines Available

For future bare-metal execution testing once HAL is implemented:

| QEMU Machine | CPU | Maps To |
|-------------|-----|---------|
| `microbit` | Cortex-M0 | BBC micro:bit |
| `mps2-an385` | Cortex-M3 | Generic Cortex-M3 |
| `mps2-an386` | Cortex-M4 | Generic Cortex-M4 |
| `mps2-an500` | Cortex-M7 | Generic Cortex-M7 |
| `mps2-an505` | Cortex-M33 | nRF5340-like (TrustZone) |
| `netduinoplus2` | Cortex-M4 | STM32F4-like |
| `lm3s6965evb` | Cortex-M3 | TI Stellaris |

## Not Supported

| Target | Reason |
|--------|--------|
| Xtensa (original ESP32) | Zig 0.15 has no Xtensa backend |
| wasm32 | `std.http` / `std.fs` incompatible with WASM (needs rearchitecture) |

## Reproducibility

```bash
# Install prerequisites
brew install zig colima docker qemu
colima start --arch aarch64 --vm-type vz --vz-rosetta
docker run --privileged tonistiigi/binfmt --install all

# Build and test all Linux targets (executed)
for target in aarch64-linux arm-linux riscv64-linux x86_64-linux powerpc64le-linux s390x-linux; do
  for profile in coding iot robotics; do
    zig build -Doptimize=ReleaseSmall -Dtarget=$target -Dprofile=$profile
    # Copy binary, build Docker image, run --version and --help
  done
done

# Build Linux targets (compile-only)
for target in mipsel-linux x86-linux loongarch64-linux mips64el-linux; do
  for profile in coding iot robotics; do
    zig build -Doptimize=ReleaseSmall -Dtarget=$target -Dprofile=$profile
  done
done

# Build freestanding MCU targets
for cpu in cortex_m0 cortex_m0plus cortex_m3 cortex_m4 cortex_m7 cortex_m23 cortex_m33 cortex_m55; do
  zig build -Doptimize=ReleaseSmall -Dtarget=thumb-freestanding -Dembedded=true -Dprofile=iot -Dcpu=$cpu
done
```
