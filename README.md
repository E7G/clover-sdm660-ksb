# Clover KS-SB Hybrid 4.19

A hybrid kernel for the **Xiaomi Mi Pad 4** (`clover`, Snapdragon SDA660 / SDM660),
combining two design philosophies instead of stacking tunables:

- **Kirisakura-style power base** — stable, low background drain, no aggressive
  overclocking, nothing that trades hardware reliability for benchmark numbers.
- **StormBreaker-style responsiveness** — WALT scheduling, KGSL tuning, short
  boosts, fewer janky frames, faster touch-to-photon.

The guiding idea is **race-to-idle**: finish the work quickly and get back to a
sleeping SoC, rather than pinning frequencies high.

> 中文简介：本项目把「Kirisakura 省电底盘」与「StormBreaker 前台响应」融合成一个
> 内核：平时桌面/浏览/视频不发热，点下去立刻响应，游戏瞬时性能快速拉起，持续负载
> 不过热，锁屏迅速进入 deep sleep。核心思路是 race-to-idle（尽快干完活回 idle），
> 而不是锁高频。详见 [设计文档](docs/superpowers/specs/2026-10-06-clover-ksb-design.md)。

## Screen-state philosophy

| State | Behaviour |
|---|---|
| Screen **ON** | StormBreaker: WALT + EAS/schedutil, short top-app/input/GPU boosts that expire quickly |
| Screen **OFF** | Kirisakura: no input boost, no GPU boost, aggressive idle, power-efficient workqueues on LITTLE, Wi-Fi power save |

## Status

| Version | Branch | Contents |
|---|---|---|
| **v0.1.0-baseline** | `ks-sb/00-baseline` | SouthWest-NG 0.18.0 + toolchain fixes + ReSukiSU manual hook + DroidSpaces configs. **No behavioural change** vs. the current device firmware — this is the A/B reference for everything that follows. |
| v0.1.1-power | `ks-sb/0x-*` | Phase 1: cpuidle / LPM / workqueue / suspend (in progress) |

## What this kernel deliberately does *not* do

- No CPU/GPU overclocking, no undervolting.
- No minimum-frequency pinning, no disabling deep idle, no permanent input boost,
  no `performance` governor, no permanently-online big cores.
- No thermal bypass / fake temperature / disabled thermal zones.
- No wholesale 5.4/5.10 subsystem ports "because newer".
- No BORE / Cachy / EEVDF scheduler replacement; no `schedhorizon` in the first release.

## Building

Requirements (verified on WSL2 `kali-linux`): `clang-22`, `ld.lld-22`, `llvm-*-22`,
`aarch64-linux-gnu` binutils, GNU make, 8+ cores, ~30 GB free disk.

```sh
tools/build.sh config     # vendor/xiaomi/sdm660_defconfig + clover.config fragment
tools/build.sh kernel     # -> $OUT/arch/arm64/boot/Image.gz
tools/build.sh package    # splice Image.gz into a copy of the stock boot image
tools/build.sh all
```

Environment overrides: `SRC`, `OUT`, `STOCK` (stock boot image), `JOBS`, `CLANG`.
The stock boot image is needed because **only `Image.gz` is rebuilt** — the ramdisk,
both device trees and the AVB metadata are reused byte-for-byte from the vendor image.

## Packaging (`tools/bootimg.py`)

The boot partition contains more than the `ANDROID!` header describes (a second dtb,
a vbmeta blob, an AVB footer at a fixed offset near the end). Shifting that unknown
region is a risk we do not take, so `repack` performs a **fixed-offset kernel splice**:

```sh
tools/bootimg.py info    stock-boot.img
tools/bootimg.py unpack  stock-boot.img outdir/
tools/bootimg.py repack  stock-boot.img Image.gz new-boot.img
tools/bootimg.py verify  stock-boot.img     # repack with the original kernel
```

`verify` on the Mi Pad 4 boot image reports **BYTE-IDENTICAL** and reproduces the
original md5 (`0196687030f210c4806e840d3571bd1b`), which is the round-trip proof that
the packer is correct. The new kernel must fit the original kernel region
(18,538,496 B, ~17.7 MiB) or the tool refuses to run.

## Flashing

```sh
# 1. ALWAYS back up the current boot partition first
adb shell su -c "dd if=/dev/block/by-name/boot of=/data/local/tmp/boot-backup.img"
adb pull /data/local/tmp/boot-backup.img

# 2. Flash (bootloader must be unlocked)
adb reboot bootloader
fastboot flash boot new-boot.img
fastboot reboot

# 3. Verify — this string must appear
adb shell cat /proc/version    # ... -Clover-KS-SB-v0.1.0-baseline ...

# 4. Roll back if anything is wrong
fastboot flash boot boot-backup.img
```

## Measuring

- `tools/measure/short.sh` — one automated pass: cpufreq/cpuidle/thermal/KGSL/memory/
  suspend counters, app launch latency (`am start -W`) and `dumpsys gfxinfo` frame
  percentiles, written to `/data/local/tmp/kss-short.json`.
- `tools/measure/sleep.sh start|end` — the 8 h screen-off Wi-Fi idle test:
  deep-sleep ratio, battery drain and wakeup-source deltas.

## Repository layout

| Path | Contents |
|---|---|
| `arch/arm64/configs/vendor/xiaomi/` | `sdm660_defconfig` + `clover.config` fragment |
| `drivers/kernelsu/` | vendored ReSukiSU kernel driver (manual hook) |
| `tools/bootimg.py` | boot image packer (header v2, fixed-offset splice) |
| `tools/build.sh` | config / kernel / package driver |
| `tools/measure/` | on-device measurement scripts |
| `docs/superpowers/specs/` | design document (Chinese) |

## Credits

- [SouthWest-NG](https://github.com/SouthWest-Kernels) 4.19 upstream base
- [ReSukiSU](https://github.com/ReSukiSU/ReSukiSU) for KernelSU integration
- Kirisakura and StormBreaker kernel projects for the design philosophies

## Disclaimer

Flashing a kernel can brick your device. You are responsible for your own hardware.
No warranty of any kind.