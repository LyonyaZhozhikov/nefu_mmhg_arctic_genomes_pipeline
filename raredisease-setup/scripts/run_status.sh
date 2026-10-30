#!/usr/bin/env bash
# Read-only snapshot of a running raredisease run: timing, task counts, what is running now, errors, load, disk.
#   bash ~/raredisease-setup/scripts/run_status.sh [LAB_CODE | RUN_DIR]
# Without an argument: the run under /data/raredisease/runs whose timing.txt changed last (the newest start).
RUNS=/data/raredisease/runs
if [ -z "$1" ]; then
    RUN=$(dirname "$(ls -t "$RUNS"/*/timing.txt 2>/dev/null | head -1)")
elif [ -d "$1" ]; then
    RUN=$1
else
    RUN=$RUNS/$1
fi
cd "$RUN" || exit 1
echo "== $(TZ=Asia/Yakutsk date '+%F %T') Yakutsk   run: $RUN"
cat timing.txt 2>/dev/null
start=$(date -d "$(sed -n 's/^\(resume_\)\{0,1\}start //p' timing.txt)" +%s 2>/dev/null) && echo "elapsed: $(( ($(date +%s)-start)/3600 )) h $(( ($(date +%s)-start)%3600/60 )) min"
sub=$(grep -ac 'Submitted process' run.log); done_=$(grep -ac 'Task completed' .nextflow.log)
echo "tasks: submitted $sub, completed $done_ (the total grows as the pipeline goes; ~250-300 for a WGS case)"
echo "-- running now:"
docker ps --format '{{.RunningFor}}\t{{.Image}}' | sed 's#community.wave.seqera.io/library/##; s#quay.io/biocontainers/##' | sort | uniq -c | head -15
echo "-- last 5 started:"; grep -a 'Submitted process' run.log | tail -5 | sed 's/.*NFCORE_RAREDISEASE://'
err=$(grep -aE 'ERROR|FAILED|Error executing' run.log | tail -3); [ -n "$err" ] && { echo "-- !! errors:"; echo "$err"; } || echo "-- no errors"
echo "-- load: $(cut -d' ' -f1-3 /proc/loadavg)   RAM used: $(free -g | awk 'NR==2 {print $3"/"$2" GB"}')   /data free: $(df -h /data | awk 'NR==2 {print $4}')"
