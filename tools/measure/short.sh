#!/system/bin/sh
# Clover KS-SB Hybrid 4.19 - short automated measurement pass.
#
#   adb push tools/measure/short.sh /data/local/tmp/ && adb shell sh /data/local/tmp/short.sh [out.json]
#
# Collects the four metric families from the design document:
#   idle/suspend, responsiveness, sustained performance, and configuration.
# Safe to run repeatedly; does not change any tunable.

OUT=${1:-/data/local/tmp/kss-short.json}
APPS="com.android.settings/.Settings com.miui.home/.launcher.Launcher"

mount -t debugfs none /sys/kernel/debug 2>/dev/null

esc() { printf '%s' "$1" | tr -d '"\\'; }
kv() { printf ' "%s":"%s"' "$1" "$(esc "$2")"; }
kn() { printf ' "%s":%s' "$1" "$2"; }

{
printf '{'
kv build "$(cat /proc/version)"
kn uptime_s "$(cut -d. -f1 /proc/uptime)"

# --- cpu frequency / governor
printf ',"cpufreq":['
first=1
for p in /sys/devices/system/cpu/cpufreq/policy*; do
  [ -d "$p" ] || continue
  [ $first -eq 1 ] || printf ','
  first=0
  printf '{'
  kv policy "$(basename $p)"
  kv governor "$(cat $p/scaling_governor 2>/dev/null)"
  kn min_khz "$(cat $p/scaling_min_freq 2>/dev/null)"
  kn max_khz "$(cat $p/scaling_max_freq 2>/dev/null)"
  printf ',"time_in_state":{'
  tfirst=1
  while read freq us; do
    [ -n "$freq" ] || continue
    [ $tfirst -eq 1 ] || printf ','
    tfirst=0
    printf '"%s":%s' "$freq" "$us"
  done < $p/stats/time_in_state
  printf '}}'
done
printf ']'

# --- cpuidle
printf ',"cpuidle":['
first=1
for s in /sys/devices/system/cpu/cpu0/cpuidle/state*; do
  [ -d "$s" ] || continue
  [ $first -eq 1 ] || printf ','
  first=0
  printf '{'
  kv name "$(cat $s/name)"
  kn disable "$(cat $s/disable)"
  kn usage "$(cat $s/usage)"
  kn time_us "$(cat $s/time)"
  printf '}'
done
printf ']'

# --- thermal
printf ',"thermal":['
first=1
for z in /sys/class/thermal/thermal_zone*; do
  [ -f "$z/temp" ] || continue
  [ $first -eq 1 ] || printf ','
  first=0
  printf '{'
  kv zone "$(basename $z)"
  kv type "$(cat $z/type 2>/dev/null)"
  kn temp_milli "$(cat $z/temp 2>/dev/null)"
  printf '}'
done
printf ']'

# --- gpu
printf ',"gpu":{'
kv governor "$(cat /sys/class/devfreq/5000000.qcom,kgsl-3d0/governor 2>/dev/null)"
kn cur_mhz "$(cat /sys/class/kgsl/kgsl-3d0/gpuclk 2>/dev/null)"
kn busy_pct "$(cat /sys/class/kgsl/kgsl-3d0/gpu_busy_percentage 2>/dev/null | tr -dc 0-9)"
kn idle_timer_ms "$(cat /sys/class/kgsl/kgsl-3d0/idle_timer 2>/dev/null)"
printf '}'

# --- memory
printf ',"memory":{'
for k in MemTotal MemFree MemAvailable Cached SwapTotal SwapFree; do
  kn "$k" "$(grep "^$k:" /proc/meminfo | tr -dc 0-9)"
done
kn zram_disksize "$(cat /sys/block/zram0/disksize 2>/dev/null)"
kv zram_comp "$(cat /sys/block/zram0/comp_algorithm 2>/dev/null)"
kv mglru "$(cat /sys/kernel/mm/lru_gen/enabled 2>/dev/null)"
kn psi_present "$([ -d /proc/pressure ] && echo 1 || echo 0)"
printf '}'

# --- suspend
printf ',"suspend":{'
if [ -f /sys/kernel/debug/suspend_stats ]; then
  for k in success fail last_failed_dev last_failed_errno; do
    v="$(grep -m1 "^$k:" /sys/kernel/debug/suspend_stats | cut -d: -f2- | tr -d ' \t')"
    [ -n "$v" ] && kv "$k" "$v"
  done
fi
printf ',"wakeup_sources":['
first=1
if [ -f /sys/kernel/debug/wakeup_sources ]; then
  head -1 /sys/kernel/debug/wakeup_sources >/dev/null
  tail -n +2 /sys/kernel/debug/wakeup_sources | sort -k6 -nr | head -12 | while read -r name active c1 c2 c3 c4 c5 c6 c7 c8; do
    [ -n "$name" ] || continue
    printf '%s{"name":"%s","active_count":%s,"active_since_ms":%s}'       "${\$first:+,}" "$name" "${active:-0}" "${c7:-0}"
    first=2
  done
fi
printf ']'
printf '}'

# --- responsiveness: app launch latency, N runs each
RUNS=${RUNS:-5}
printf ',"app_launch_ms":['
first=1
for a in $APPS; do
  for i in $(seq 1 $RUNS); do
    am force-stop "${a%%/*}" 2>/dev/null
    sleep 1
    t=$(am start -W -n "$a" 2>/dev/null | grep -m1 TotalTime | tr -dc 0-9)
    [ -n "$t" ] || continue
    [ $first -eq 1 ] || printf ','
    first=0
    printf '{"app":"%s","total_ms":%s}' "$a" "$t"
    sleep 1
  done
done
printf ']'

# --- frame stats
printf ',"gfxinfo":{'
kn total_frames "$(dumpsys gfxinfo 2>/dev/null | grep -m1 'Total frames rendered' | tr -dc 0-9)"
kn janky_frames "$(dumpsys gfxinfo 2>/dev/null | grep -m1 'Janky frames' | tr -dc 0-9)"
kn p50_ms "$(dumpsys gfxinfo 2>/dev/null | grep -m1 '50th percentile' | tr -dc 0-9)"
kn p90_ms "$(dumpsys gfxinfo 2>/dev/null | grep -m1 '90th percentile' | tr -dc 0-9)"
kn p95_ms "$(dumpsys gfxinfo 2>/dev/null | grep -m1 '95th percentile' | tr -dc 0-9)"
kn p99_ms "$(dumpsys gfxinfo 2>/dev/null | grep -m1 '99th percentile' | tr -dc 0-9)"
printf '}'

printf '}\n'
} > "$OUT" 2>/dev/null

echo "wrote $OUT"
