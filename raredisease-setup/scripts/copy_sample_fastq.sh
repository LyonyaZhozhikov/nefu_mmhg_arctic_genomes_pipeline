#!/usr/bin/env bash
# Copy one sample's FASTQ from the dock drive by lab code, one file at a time, then verify sizes.
# Usage: copy_sample_fastq.sh <LAB_CODE> [SRC_ROOT]   (log: ~/copy_<LAB_CODE>.log)
# The source folder is found by the lab code in the FASTQ names, and the script cd's into it, so the
# folder name (it holds the patient's name) never reaches paths, logs or the destination.
CODE=$1
ROOT=${2:-"/mnt/e/EVOGEN 21.09.26"}
DST=/data/raredisease/samples/$CODE
first=$(find "$ROOT" -maxdepth 3 -name "${CODE}_*.fq.gz" -print -quit)
[ -n "$first" ] || { echo "no ${CODE}_*.fq.gz under the source root"; exit 1; }
cd "$(dirname "$first")" || exit 1
mkdir -p "$DST"
echo "start $(TZ=Asia/Yakutsk date '+%F %T')"
for f in "${CODE}"_*.fq.gz; do
    rsync -t --partial "$f" "$DST/" || echo "rsync $f exit $?"
    echo "$(TZ=Asia/Yakutsk date '+%T') $f"
done
for f in "${CODE}"_*.fq.gz *.md5 md5*.txt; do [ -e "$f" ] || continue; case "$f" in *.md5|md5*) cp -p "$f" "$DST/";; esac; done
bad=0
for f in "${CODE}"_*.fq.gz; do
    a=$(stat -c %s "$f"); b=$(stat -c %s "$DST/$f" 2>/dev/null)
    [ "$a" = "$b" ] || { echo "SIZE MISMATCH $f $a $b"; bad=1; }
done
sum() { stat -c %s "$@" | awk '{n++; s+=$1} END {print n " files, " s " bytes"}'; }
echo "src: $(sum "${CODE}"_*.fq.gz) | dst: $(sum "$DST"/"${CODE}"_*.fq.gz)"
[ $bad = 0 ] && echo "sizes OK"
echo "end $(TZ=Asia/Yakutsk date '+%F %T')"
