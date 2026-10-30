#!/usr/bin/env bash
# Light watcher for a raredisease run (fnd_watch.sh with run-specific log and interval): one status line per
# interval to $OUT, including RAM/swap of the shared WSL2 VM and whether the "scout" distro is running
# (its Mongo shares that RAM). Stops after timing.txt gets its exit/end line.
# Usage: run_watch.sh <RUN_DIR> [interval_s]   (OUT defaults to <RUN_DIR>/watch.log)
RUN=${1:?run dir}
EVERY=${2:-600}
OUT=${OUT:-$RUN/watch.log}
while :; do
  last=$(grep -aE 'Submitted process|COMPLETED|FAILED|ERROR' "$RUN/run.log" 2>/dev/null | tail -1 | cut -c1-160)
  ntask=$(grep -ac 'Submitted process' "$RUN/run.log" 2>/dev/null)
  load=$(cut -d' ' -f1-3 /proc/loadavg)
  free=$(df -h /data | awk 'NR==2 {print $4}')
  mem=$(free -g | awk '/^Mem/ {u=$3; a=$7} /^Swap/ {s=$3} END {print "RAM used " u " GB, avail " a " GB, swap " s " GB"}')
  # A long-lived tmux server can hold a stale WSL_INTEROP socket, which makes wsl.exe fail; try the live ones.
  scout=unknown
  for s in "$WSL_INTEROP" /run/WSL/*_interop; do
    l=$(WSL_INTEROP=$s wsl.exe -l --running 2>/dev/null | tr -d '\0\r') || continue
    [ -n "$l" ] || continue
    grep -qx ' *scout.*' <<< "$l" && scout=on || scout=off
    break
  done
  echo "$(TZ=Asia/Yakutsk date '+%F %T') | submitted=$ntask | load $load | $mem | scout $scout | /data free $free | $last" >> "$OUT"
  grep -qE '^(exit|end) ' "$RUN/timing.txt" 2>/dev/null && { echo "$(TZ=Asia/Yakutsk date '+%F %T') | run finished: $(tr '\n' ' ' < "$RUN/timing.txt")" >> "$OUT"; break; }
  sleep "$EVERY"
done
