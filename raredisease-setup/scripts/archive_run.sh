#!/usr/bin/env bash
# Archive copy of a finished case to D: (copy + verify only; nothing is deleted).
# Usage: archive_run.sh <LAB_CODE> <archive folder name, e.g. 2026-10-27_SAMPLE02_M>   (log: ~/archive_<LAB_CODE>.log)
set -o pipefail
CODE=${1:?lab code}
SRC_RAW=/data/raredisease/samples/$CODE
RUN=/data/raredisease/runs/$CODE
DST=/mnt/d/data_annotated/${2:?archive folder name}
mkdir -p "$DST/raw" "$DST/processed/run_info"
echo "start $(TZ=Asia/Yakutsk date '+%F %T')"
rsync -rtL "$SRC_RAW/" "$DST/raw/" || echo "rsync raw exit $?"
rsync -rtL "$RUN/results" "$DST/processed/" || echo "rsync results exit $?"
for f in "$RUN"/*.log "$RUN"/timing*.txt "$RUN"/timing_summary.tsv "$RUN"/run_info.txt "$RUN"/params.yaml* \
         "$RUN"/samplesheet.csv "$RUN"/launch*.sh "$RUN"/local.config.at_launch; do
    [ -e "$f" ] && cp -p "$f" "$DST/processed/run_info/"
done
cp -p /home/ngs/raredisease-setup/conf/vep_spliceai_cadd.config "$DST/processed/run_info/"
[ -e "$RUN/local.config.at_launch" ] || cp -p /home/ngs/raredisease-setup/conf/local.config "$DST/processed/run_info/"
echo "copied $(TZ=Asia/Yakutsk date '+%F %T')"
# verify: file count and total bytes of each tree (symlinks followed on the source side, as rsync -L did)
cmp_tree() {
    local a b
    a=$(find -L "$1" -type f -printf '%s\n' | awk '{n++; s+=$1} END {print n, s}')
    b=$(find "$2" -type f -printf '%s\n' | awk '{n++; s+=$1} END {print n, s}')
    echo "$3 src: $a | dst: $b | $([ "$a" = "$b" ] && echo OK || echo MISMATCH)"
}
cmp_tree "$SRC_RAW" "$DST/raw" raw
cmp_tree "$RUN/results" "$DST/processed/results" results
(cd "$SRC_RAW" && md5sum *.fq.gz) > "/tmp/${CODE}_src.md5"
(cd "$DST/raw" && md5sum -c "/tmp/${CODE}_src.md5") | grep -c ': OK$' | sed 's/^/raw md5 OK files: /'
echo "end $(TZ=Asia/Yakutsk date '+%F %T')"
