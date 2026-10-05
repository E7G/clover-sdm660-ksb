#!/system/bin/sh
# Clover KS-SB Hybrid 4.19 - suspend / idle-longevity measurement.
#
# Long test (8h) is run by the device user, not automatically:
#
#   adb shell sh /data/local/tmp/sleep.sh start     # before going to bed
#   ... leave the device locked on Wi-Fi for 8h ...
#   adb shell sh /data/local/tmp/sleep.sh end       # in the morning
#
# start snapshots battery, suspend counters, wakeup_sources and cpuidle.
# end   snapshots again and prints the deltas (deep sleep ratio, drain, wakeups).
# POSIX sh only - no bash process substitution (Android sh is mksh).

DIR=${KSS_SLEEP_DIR:-/data/local/tmp/kss-sleep}
mkdir -p "$DIR"

snapshot() {
	f="$1"
	mount -t debugfs none /sys/kernel/debug 2>/dev/null
	{
		echo "time=$(date +%s)"
		echo "battery_capacity=$(dumpsys battery 2>/dev/null | grep -m1 " level:" | tr -dc 0-9)"
		echo "battery_voltage=$(dumpsys battery 2>/dev/null | grep -m1 " voltage:" | tr -dc 0-9)"
		echo "uptime=$(cut -d. -f1 /proc/uptime)"
		echo "--suspend_stats"
		cat /sys/kernel/debug/suspend_stats 2>/dev/null
		echo "--cpuidle"
		for s in /sys/devices/system/cpu/cpu0/cpuidle/state*; do
			echo "$(basename $s) $(cat $s/name) usage=$(cat $s/usage) time=$(cat $s/time)"
		done
		echo "--wakeup_sources"
		cat /sys/kernel/debug/wakeup_sources 2>/dev/null
		echo "--interrupts"
		cat /proc/interrupts
	} > "$f"
	echo "snapshot -> $f"
}

case "${1:-}" in
	start) snapshot "$DIR/before.txt" ;;
	end)
		snapshot "$DIR/after.txt"
		echo
		echo "=== battery (capacity / voltage)"
		echo "before: $(grep battery_capacity "$DIR/before.txt") $(grep battery_voltage "$DIR/before.txt")"
		echo "after:  $(grep battery_capacity "$DIR/after.txt") $(grep battery_voltage "$DIR/after.txt")"
		echo
		echo "=== elapsed hours"
		awk '/^time=/{sub("time=","");t[++n]=$1} END{if(n==2) printf "  %.2f h\n", (t[2]-t[1])/3600}' "$DIR/before.txt" "$DIR/after.txt"
		echo
		echo "=== suspend_stats"
		echo "before:"; sed -n '/--suspend_stats/,/--cpuidle/p' "$DIR/before.txt" | head -12
		echo "after:";  sed -n '/--suspend_stats/,/--cpuidle/p' "$DIR/after.txt"  | head -12
		echo
		echo "=== wakeup_sources delta (top 20 by active_count change)"
		awk 'FNR==NR { if ($1 !~ /^--/ && NF>5) before[$1]=$6; next }
		          $1 !~ /^--/ && NF>5 { printf "%s %s %s\n", $1, (($1 in before)?before[$1]:"0"), $6 }' \
			"$DIR/before.txt" "$DIR/after.txt" | sort -k3 -nr | head -20
		echo
		echo "full snapshots: $DIR/before.txt $DIR/after.txt"
		;;
	*) echo "usage: $0 {start|end}" >&2; exit 2 ;;
esac