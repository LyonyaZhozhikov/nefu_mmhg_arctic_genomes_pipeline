#!/usr/bin/env bash
# Build Picard interval lists that match YOUR reference dictionary.
# The lists bundled with the pipeline (assets/*grch38*.interval_list) carry a 3366-contig header from the
# full GRCh38+alt+decoy+HLA reference; Picard refuses them with the 195-contig no-alt analysis set.
# Usage: bash make_interval_lists.sh <reference.dict> <outdir>
set -euo pipefail
DICT=${1:?reference .dict}; OUT=${2:?output dir}
grep '^@' "$DICT" > "$OUT/grch38_noalt_wgs.interval_list"
grep '^@' "$DICT" > "$OUT/grch38_noalt_chrY.interval_list"
awk -F'\t' '$1=="@SQ"{sub("SN:","",$2); sub("LN:","",$3); print $2"\t"$3}' "$DICT" \
 | awk -v OFS='\t' '$1 ~ /^chr([0-9]+|X|Y|M)$/ {print $1,1,$2,"+","."}' >> "$OUT/grch38_noalt_wgs.interval_list"
awk -F'\t' '$1=="@SQ"{sub("SN:","",$2); sub("LN:","",$3); if ($2=="chrY") print $2"\t1\t"$3"\t+\t."}' "$DICT" \
 >> "$OUT/grch38_noalt_chrY.interval_list"
echo "wrote $OUT/grch38_noalt_wgs.interval_list ($(grep -vc '^@' "$OUT/grch38_noalt_wgs.interval_list") intervals) and grch38_noalt_chrY.interval_list"
