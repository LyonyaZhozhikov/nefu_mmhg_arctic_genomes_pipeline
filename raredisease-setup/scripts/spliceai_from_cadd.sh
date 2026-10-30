#!/usr/bin/env bash
set -euo pipefail
REF=${REF:-/data/raredisease/references/grch38}
SRC=$REF/cadd_annotations/GRCh38_v1.7/spliceai/spliceai_scores.masked.all.hg38.tsv.gz
OUT=$REF/vep_plugin_files/spliceai_masked_cadd_grch38.vcf.gz
TMP=$REF/downloads_scores/spliceai_tmp
JOBS=${JOBS:-8}
export SRC TMP
mkdir -p "$TMP"
log() { echo "[$(date '+%F %T')] $*"; }
one_contig() {
  local part="$TMP/$1.vcf.gz"
  [ -s "$part" ] && return 0
  tabix "$SRC" "$2" | awk -F'\t' -v OFS='\t' '{print "chr"$1, $2, ".", $3, $4, ".", ".", "SpliceAI="$4"|"$5"|.|.|.|."}' | bgzip -c > "$part.tmp" && mv "$part.tmp" "$part" && echo "  done $2"
}
export -f one_contig
log "start: $SRC"
{ echo '##fileformat=VCFv4.2'
  echo '##source=SpliceAI v1.3 precomputed MASKED scores from the CADD v1.7 annotations (no delta positions)'
  echo '##INFO=<ID=SpliceAI,Number=.,Type=String,Description="SpliceAIv1.3 variant annotation. These include delta scores (DS) and delta positions (DP) for acceptor gain (AG), acceptor loss (AL), donor gain (DG), and donor loss (DL). Format: ALLELE|SYMBOL|DS_AG|DS_AL|DS_DG|DS_DL|DP_AG|DP_AL|DP_DG|DP_DL">'
  printf '#CHROM\tPOS\tID\tREF\tALT\tQUAL\tFILTER\tINFO\n'; } | bgzip -c > "$TMP/00000.vcf.gz"
tabix -l "$SRC" | awk '{printf "%05d\t%s\n", NR, $1}' | xargs -P "$JOBS" -L 1 bash -c 'one_contig "$0" "$1"'
n_want=$(( $(tabix -l "$SRC" | wc -l) + 1 )); n_have=$(ls "$TMP"/*.vcf.gz | wc -l)
[ "$n_have" -eq "$n_want" ] || { log "!! only $n_have of $n_want pieces, rerun to resume"; exit 1; }
log "concatenating"; cat $(ls "$TMP"/*.vcf.gz | sort) > "$OUT.tmp" && mv "$OUT.tmp" "$OUT"
log "indexing"; tabix -f -p vcf "$OUT"
log "check: contigs $(tabix -l "$OUT" | wc -l)"; zcat "$OUT" | grep -v '^#' | head -2
rm -rf "$TMP"; log "DONE $OUT ($(du -h "$OUT" | cut -f1))"
