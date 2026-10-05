#!/system/bin/sh
# Clover KS-SB Hybrid 4.19 - short automated measurement pass (POSIX/mksh safe).
#
#   adb push tools/measure/short.sh /data/local/tmp/
#   adb shell su -c 'sh /data/local/tmp/short.sh /data/local/tmp/kss-short.json' < /dev/null
#
# Root is only needed to mount debugfs (suspend_stats, wakeup_sources); on stock
# firmware CONFIG_DEBUG_FS is off, so those sections stay empty. This script
# changes no tunable. Always redirect stdin from /dev/null: some sysfs
# attributes (e.g. thermal_zone*/temp on pm660) return EINVAL on read, and any
# helper that inherits an interactive stdin would block forever on them.

OUT=${1:-/data/local/tmp/kss-short.json}
RUNS=${RUNS:-5}
LABEL=${LABEL:-unset}

# ---- debugfs: /sys/kernel/debug may not exist at all; fall back to a tmpfs dir
mount -t debugfs none /sys/kernel/debug 2>/dev/null
DBG=/sys/kernel/debug
if [ ! -r $DBG/suspend_stats ]; then
  mkdir -p /data/local/tmp/dbg 2>/dev/null
  mount -t debugfs none /data/local/tmp/dbg 2>/dev/null
  [ -r /data/local/tmp/dbg/suspend_stats ] && DBG=/data/local/tmp/dbg
fi

num()   { v=$(cat "$1" 2>/dev/null | tr -dc 0-9); printf '%s' "${v:-0}"; }
rd()    { cat "$1" 2>/dev/null; }
clean() { tr -d '"\\'; }
mem()   { grep "^$1:" /proc/meminfo | tr -dc 0-9; }
field() { sed -n "s/.*$1: *\([0-9][0-9]*\).*/\1/p" "$2" 2>/dev/null | head -1; }
TO()    { if command -v timeout >/dev/null 2>&1; then timeout 90 "$@"; else "$@"; fi; }
f0()    { v=$(field "$1" "$2"); printf '%s' "${v:-0}"; }

LAUNCHER=$(cmd package resolve-activity --brief -a android.intent.action.MAIN -c android.intent.category.HOME 2>/dev/null | tail -1)
case "$LAUNCHER" in */*) ;; *) LAUNCHER="" ;; esac
# NOTE: the HOME/launcher app is deliberately NOT measured.  Android relaunches
# the HOME app immediately after `am force-stop`, so `am start -W` there times a
# warm resume of an already-running task (observed on clover: TotalTime 0 ms,
# while a genuine cold start of the same build measures ~530 ms).  Comparing it
# A/B measures framework restart semantics, not kernel performance.
APPS=${APPS:-"com.android.settings/.Settings com.android.deskclock/.DeskClock com.android.documentsui/.LauncherActivity com.android.contacts/.activities.PeopleActivity org.lineageos.jelly/.MainActivity"}

{
printf '{'
printf '"label":"%s"' "$LABEL"
printf ',"build":"%s"' "$(rd /proc/version | clean)"
printf ',"model":"%s"' "$(getprop ro.product.model | clean)"
printf ',"android":"%s"' "$(getprop ro.build.version.release | clean)"
printf ',"uptime_s":%s' "$(cut -d. -f1 /proc/uptime)"

printf ',"cpufreq":['
f=1
for p in /sys/devices/system/cpu/cpufreq/policy*; do
  [ -d "$p" ] || continue
  [ $f -eq 1 ] || printf ','
  f=0
  printf '{"policy":"%s","governor":"%s","min_khz":%s,"max_khz":%s,"time_in_state":{' \
    "$(basename $p)" "$(rd $p/scaling_governor | clean)" "$(num $p/scaling_min_freq)" "$(num $p/scaling_max_freq)"
  t=1
  while read freq us; do
    [ -n "$freq" ] || continue
    [ $t -eq 1 ] || printf ','
    t=0
    printf '"%s":%s' "$freq" "${us:-0}"
  done < $p/stats/time_in_state
  printf '}}'
done
printf ']'

printf ',"cpuidle":['
f=1
for s in /sys/devices/system/cpu/cpu0/cpuidle/state*; do
  [ -d "$s" ] || continue
  [ $f -eq 1 ] || printf ','
  f=0
  printf '{"name":"%s","disable":%s,"usage":%s,"time_us":%s}' \
    "$(rd $s/name | clean)" "$(num $s/disable)" "$(num $s/usage)" "$(num $s/time)"
done
printf ']'

printf ',"thermal":['
f=1
for z in /sys/class/thermal/thermal_zone*; do
  [ -f "$z/temp" ] || continue
  [ $f -eq 1 ] || printf ','
  f=0
  printf '{"zone":"%s","type":"%s","mode":"%s","governor":"%s","temp_milli":%s,"trip_count":%s}' \
    "$(basename $z)" "$(rd $z/type | clean)" "$(rd $z/mode | clean)" "$(rd $z/policy | clean)" \
    "$(num $z/temp)" "$(ls -1 $z/trip_point_*_temp 2>/dev/null | wc -l | tr -dc 0-9)"
done
printf ']'

printf ',"cooling":['
f=1
for c in /sys/class/thermal/cooling_device*; do
  [ -d "$c" ] || continue
  [ $f -eq 1 ] || printf ','
  f=0
  printf '{"type":"%s","cur_state":%s,"max_state":%s}' \
    "$(rd $c/type | clean)" "$(num $c/cur_state)" "$(num $c/max_state)"
done
printf ']'

printf ',"gpu":{"governor":"%s","cur_hz":%s,"busy_pct":%s,"idle_timer_ms":%s,"min_pwrlevel":"%s","max_pwrlevel":"%s"}' \
  "$(rd /sys/class/devfreq/5000000.qcom,kgsl-3d0/governor | clean)" \
  "$(num /sys/class/kgsl/kgsl-3d0/gpuclk)" \
  "$(num /sys/class/kgsl/kgsl-3d0/gpu_busy_percentage)" \
  "$(num /sys/class/kgsl/kgsl-3d0/idle_timer)" \
  "$(rd /sys/class/kgsl/kgsl-3d0/min_pwrlevel | clean)" \
  "$(rd /sys/class/kgsl/kgsl-3d0/max_pwrlevel | clean)"

printf ',"memory":{"MemTotal":%s,"MemFree":%s,"MemAvailable":%s,"Cached":%s,"SwapTotal":%s,"SwapFree":%s,"zram_disksize":%s,"zram_comp":"%s","mglru":"%s","psi_present":%s,"workqueue_cpumask":"%s"}' \
  "$(mem MemTotal)" "$(mem MemFree)" "$(mem MemAvailable)" "$(mem Cached)" \
  "$(mem SwapTotal)" "$(mem SwapFree)" \
  "$(num /sys/block/zram0/disksize)" "$(rd /sys/block/zram0/comp_algorithm | clean)" \
  "$(rd /sys/kernel/mm/lru_gen/enabled | clean)" \
  "$([ -d /proc/pressure ] && echo 1 || echo 0)" \
  "$(rd /sys/devices/virtual/workqueue/cpumask | clean)"

printf ',"suspend":{"debugfs":"%s","stats":{' "$([ -r $DBG/suspend_stats ] && echo yes || echo no)"
f=1
if [ -r $DBG/suspend_stats ]; then
  while IFS=: read k v; do
    case "$k" in
      success|fail|last_failed_dev|last_failed_errno|last_failed_step)
        v=$(printf '%s' "$v" | clean)
        [ -n "$v" ] || continue
        [ $f -eq 1 ] || printf ','
        f=0
        printf '"%s":"%s"' "$k" "$v" ;;
    esac
  done < $DBG/suspend_stats
fi
printf '},"wakeup_sources":['
if [ -r $DBG/wakeup_sources ]; then
  awk 'NR>1 && NF>=7 {print $7"\t"$1"\t"$2"\t"$6}' $DBG/wakeup_sources 2>/dev/null \
    | sort -k1,1nr | head -12 \
    | awk 'BEGIN{n=0} {printf "%s{\"name\":\"%s\",\"total_time_ms\":%s,\"active_count\":%s,\"active_since_ms\":%s}", (n++?",":""), $2,$1,$3,$4}'
fi
printf ']}'

printf ',"app_launch_ms":['
f=1
for a in $APPS; do
  [ -n "$a" ] || continue
  i=1
  while [ $i -le $RUNS ]; do
    i=$((i+1))
    pkg=${a%%/*}
    am force-stop "$pkg" 2>/dev/null
    # am force-stop is asynchronous: wait until the process is really gone so the
    # sample is a genuine cold start (LaunchState COLD).  A launch that still has
    # a live process is WARM and must not be compared across builds.
    n=0
    while [ $n -lt 12 ]; do
      pidof "$pkg" >/dev/null 2>&1 || break
      sleep 0.25
      n=$((n+1))
    done
    o=$(am start -W -n "$a" 2>/dev/null)
    t=$(printf '%s' "$o" | grep -m1 TotalTime | tr -dc 0-9)
    st=$(printf '%s' "$o" | grep -m1 LaunchState | sed 's/.*LaunchState: *//' | tr -dc 'A-Z')
    [ -n "$t" ] || continue
    [ $f -eq 1 ] || printf ','
    f=0
    printf '{"app":"%s","total_ms":%s,"state":"%s"}' "$a" "$t" "$st"
    sleep 1
  done
done
printf ']'

printf ',"gfxinfo":['
f=1
GF=/data/local/tmp/.kss-gfxinfo.txt
for a in $APPS; do
  [ -n "$a" ] || continue
  am force-stop "${a%%/*}" 2>/dev/null
  sleep 1
  am start -W -n "$a" >/dev/null 2>&1
  sleep 4
  TO dumpsys gfxinfo "${a%%/*}" 2>/dev/null > $GF
  [ $f -eq 1 ] || printf ','
  f=0
  printf '{"app":"%s","total_frames":%s,"janky_frames":%s,"p50_ms":%s,"p90_ms":%s,"p95_ms":%s,"p99_ms":%s}' \
    "${a%%/*}" \
    "$(f0 'Total frames rendered' $GF)" "$(f0 'Janky frames' $GF)" \
    "$(f0 '50th percentile' $GF)" "$(f0 '90th percentile' $GF)" \
    "$(f0 '95th percentile' $GF)" "$(f0 '99th percentile' $GF)"
done
rm -f $GF
printf ']'

printf '}\n'
} > "$OUT" 2>/dev/null

echo "wrote $OUT"
wc -c < "$OUT"