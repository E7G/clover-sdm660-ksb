# Clover KS-SB Hybrid — validation record

Validated on Xiaomi Mi Pad 4 (clover), Snapdragon 660 / Adreno 512, Linux 4.19.325-cip135-st19.

## Current validated stack

- Baseline: `v0.1.0-baseline` — fair stock comparison after disabling the asymmetric KSU module stack.
- SUSFS: v1.5.9, ReSukiSU non-GKI integration.
- Power foundation: schedutil default; WQ power-efficient default retained.
- Response: 180 ms event-gated input burst; no global scheduler boost.
- KGSL: keep high-priority KGSL workqueue, remove only the dedicated `kgsl_worker_thr` SCHED_RR/6 policy.
- Memory: keep existing MGLRU/PSI/3 GiB zram and LZO-RLE; do not force LZ4.
- I/O: mq-deadline selected after controlled direct-read + cold-launch ABBA testing.
- Thermal: valid TSENS fallback with staged Gold-first/Silver-second cpufreq cooling.
- Profiles: battery / balanced / performance, all using short reversible input bursts only.

## Baseline findings

Earlier apparent regressions were caused by an asymmetric comparison: the Clover KernelSU boot automatically loaded the user's KSU module stack, while stock was unrooted.

With modules disabled for the fair comparison:

| Metric | stock | Clover |
| --- | ---: | ---: |
| MemAvailable | 2,068,656 KB | 2,043,872 KB |
| AnonPages | 722,332 KB | 732,684 KB |
| ZRAM | 2,809,072 KB | 2,809,604 KB |
| Settings cold launch P50/P95 | 616/795 ms | 607/732 ms |
| DeskClock cold launch P50/P95 | 599/673 ms | 602/659 ms |
| Jelly cold launch P50/P95 | 810/870 ms | 800/838 ms |

The stable kernel-only memory cost was approximately +29 MB slab.

## Response layer

Final default burst:

- Silver: 1.4016 GHz
- Gold: 1.7472 GHz
- Duration: 180 ms
- `sched_boost_on_input=0`
- Trigger only on real key press / new MT tracking ID; coordinate motion does not renew the burst.

Measured behavior:

- T+50 ms: policy mins rise to the requested burst frequencies.
- T+250/350 ms: policy mins return to 633.6 MHz / 1.1136 GHz.
- Long scrolling does not continuously refresh boost.

## KGSL selection

Three behaviors were compared:

1. Baseline KGSL behavior.
2. Remove only `kgsl_worker_thr` SCHED_RR/6, retain WQ_HIGHPRI.
3. Remove both SCHED_RR and WQ_HIGHPRI.

Five-round Settings scroll test:

| Variant | Jank | Jank rate | P95 median |
| --- | ---: | ---: | ---: |
| baseline | 33 / 4439 | 0.74% | 25 ms |
| no-RT only | 27 / 4417 | 0.61% | 21 ms |
| no-RT + no-WQ_HIGHPRI | 35 / 4433 | 0.79% | worse than no-RT-only |

Decision: retain WQ_HIGHPRI; only change the dedicated KGSL worker to SCHED_OTHER/0.

## ZRAM compressor test

Controlled same-kernel ABBA test using the same fixed 128 MiB mixed corpus:

- LZO-RLE: 6610 ms / 5840 ms; mean ≈ 6225 ms
- LZ4: 6890 ms / 5920 ms; mean ≈ 6405 ms

No repeatable LZ4 speed advantage was demonstrated. Compression accounting was noisy because reclaim behavior changed between passes.

Decision: keep LZO-RLE. Do not change a stable memory path just to match a theoretical plan.

## I/O scheduler selection

Controlled direct-read background contention with cold app launches, same kernel and similar 42–46 °C thermal window.

Aggregated second-round results:

| App | mq-deadline mean/P95 | Kyber mean/P95 |
| --- | ---: | ---: |
| DeskClock | 622.5 / 661.9 ms | 631.2 / 701.5 ms |
| Jelly | 847.5 / 886.1 ms | 854.9 / 901.0 ms |

Decision: mq-deadline is the default. BFQ is not retained as default.

## Thermal fallback

The original PM660 quiet-therm ADC path was not usable on the current stack. The fallback reuses a valid TSENS channel.

Policy:

- Gold trip: 78 °C, 3 °C hysteresis.
- Silver trip: 82 °C, 3 °C hysteresis.
- Existing 105 °C emergency isolation remains.
- step_wise governor remains intact.

180-second all-core CPU stress:

- Start: 46.6 °C.
- Gold mitigation begins first.
- Long-run zone temperature stabilizes around 75–77.6 °C.
- Gold settles around state 2/3, reaching an effective 1.7472 GHz sustained ceiling.
- Silver remains state 0 throughout this run.
- No panic or reboot.
- Two seconds after load removal: 55.3 °C; both cooling states return to 0.

## Profiles

`/sys/devices/system/cpu/cpu_boost/profile`

### battery

- 180 ms
- Silver 1.1136 GHz
- Gold 1.4016 GHz
- no scheduler-wide boost

### balanced (default)

- 180 ms
- Silver 1.4016 GHz
- Gold 1.7472 GHz
- no scheduler-wide boost

### performance

- 220 ms
- Silver 1.536 GHz
- Gold 1.9584 GHz
- no scheduler-wide boost

Profiles do not change WALT, schedutil, KGSL governor/frequency limits, I/O scheduler, or thermal rules.

## Current persistent device state

After flashing `v0.8.0-profile`:

- kernel: `4.19.325-cip135-st19-Clover-KS-SB-v0.8.0-profile`
- profile: balanced
- input boost: 180 ms, 1.4016/1.7472 GHz
- I/O: mq-deadline
- SUSFS: v1.5.9
- KSU root: working
- thermal fallback: 78/82 °C trips present

## Still required before a stable release

These are intentionally not marked complete yet:

- 8-hour screen-off standby: deep sleep ≥95% target and battery drop observation.
- 20–30 minute sustained workload: CPU/GPU frequency, thermal zone, throttling curve and stability.
- Long gfxinfo/frame-time sample across the main UI and representative apps.
- Final hardware regression pass: Wi-Fi, BT, audio, camera, charging, USB, touch, sensors, notifications/downloads/ADB.

Until those are complete, treat the current branch as a release candidate rather than the final stable release.
