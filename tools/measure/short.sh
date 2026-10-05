#!/system/bin/sh
# Clover KS-SB Hybrid 4.19 - short automated measurement pass (POSIX/mksh safe).
#
#   adb push tools/measure/short.sh /data/local/tmp/
#   adb shell su -c 'sh /data/local/tmp/short.sh /data/local/tmp/kss-short.json'
#
# Root is only needed for debugfs (suspend_stats, wakeup_sources); everything
# else works as the shell user. This script changes no tunable.

OUT=${1:-/data/local/tmp/kss-short.json}
RUNS=${RUNS:-5}
LABEL=${LABEL:-unset}

mount -t debugfs none /sys/kernel/debug 2>/dev/null
rd()  { cat "$1" 2>/dev/null; }
num() { tr -dc 0-9 < "$1" 2>/dev/null; }
clean() { tr -d '"\\' ; }
mem() { grep "^$1:" /proc/meminfo | tr -dc 0-9; }

LAUNCHER=$(cmd package resolve-activity --brief -c android.intent.category.HOME 2>/dev/null | tail -1)
APPS=${APPS:-"com.android.settings/.Settings $LAUNCHER"}

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
    "$(basename $p)" "$(rd $p/scaling_governor)" "$(num $p/scaling_min_freq)" "$(num $p/scaling_max_freq)"
  t=1
  while read freq us; do
    [ -n "$freq" ] || continue
    [ $t -eq 1 ] || printf ','
    t=0
    printf '"%s":%s' "$freq" "$us"
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
    "$(rd $s/name)" "$(num $s/disable)" "$(num $s/usage)" "$(num $s/time)"
done
printf ']'

printf ',"thermal":['
f=1
for z in /sys/class/thermal/thermal_zone*; do
  [ -f "$z/temp" ] || continue
  [ $f -eq 1 ] || printf ','
  f=0
  printf '{"zone":"%s","type":"%s","temp_milli":%s}' "$(basename $z)" "$(rd $z/type)" "$(num $z/temp)"
done
printf ']'

printf ',"gpu":{"governor":"%s","cur_hz":%s,"busy_pct":%s,"idle_timer_ms":%s,"min_pwrlevel":"%s","max_pwrlevel":"%s"}' \
  "$(rd /sys/class/devfreq/5000000.qcom,kgsl-3d0/governor)" \
  "$(num /sys/class/kgsl/kgsl-3d0/gpuclk)" \
  "$(rd /sys/class/kgsl/kgsl-3d0/gpu_busy_percentage | tr -dc 0-9)" \
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

printf ',"suspend":{"stats":{'
f=1
if [ -f /sys/kernel/debug/suspend_stats ]; then
  while IFS=: read k v; do
    case "$k" in
      success|fail|last_failed_dev|last_failed_errno|last_failed_step)
        v=$(printf '%s' "$v" | clean)
        [ -n "$v" ] || continue
        [ $f -eq 1 ] || printf ','
        f=0
        printf '"%s":"%s"' "$k" "$v" ;;
    esac
  done < /sys/kernel/debug/suspend_stats
fi
printf '},"wakeup_sources":['
awk 'NR>1 && NF>=7 {print $7"\t"$1"\t"$2"\t"$6}' /sys/kernel/debug/wakeup_sources 2>/dev/null \
  | sort -k1,1nr | head -12 \
  | awk 'BEGIN{n=0} {printf "%s{\"name\":\"%s\",\"total_time_ms\":%s,\"active_count\":%s,\"active_since_ms\":%s}", (n++?",":""), $2,$1,$3,$4}'
printf ']}'
printf '}'

printf ',"app_launch_ms":['
f=1
for a in $APPS; do
  [ -n "$a" ] || continue
  i=1
  while [ $i -le $RUNS ]; do
    i=$((i+1))
    am force-stop "${a%%/*}" 2>/dev/null
    sleep 1
    t=$(am start -W -n "$a" 2>/dev/null | grep -m1 TotalTime | tr -dc 0-9)
    [ -n "$t" ] || continue
    [ $f -eq 1 ] || printf ','
    f=0
    printf '{"app":"%s","total_ms":%s}' "$a" "$t"
    sleep 1
  done
done
printf ']'

printf ',"gfxinfo":{'
GF=/data/local/tmp/.kss-gfxinfo.txt
dumpsys gfxinfo 2>/dev/null > $GF
printf '"total_frames":%s,"janky_frames":%s,"p50_ms":%s,"p90_ms":%s,"p95_ms":%s,"p99_ms":%s' \
  "$(grep -m1 'Total frames rendered' $GF | tr -dc 0-9)" \
  "$(grep -m1 'Janky frames' $GF | tr -dc 0-9)" \
  "$(grep -m1 '50th percentile' $GF | tr -dc 0-9)" \
  "$(grep -m1 '90th percentile' $GF | tr -dc 0-9)" \
  "$(grep -m1 '95th percentile' $GF | tr -dc 0-9)" \
  "$(grep -m1 '99th percentile' $GF | tr -dc 0-9)"
rm -f $GF
printf '}'

printf '}\n'
} > "$OUT" 2>/dev/null

echo "wrote $OUT"
wc -c < "$OUT"