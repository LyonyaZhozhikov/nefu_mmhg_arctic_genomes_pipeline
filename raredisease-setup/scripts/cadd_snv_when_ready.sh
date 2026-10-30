#!/usr/bin/env bash
# Waits until aria2c has finished vcfanno/whole_genome_SNVs.tsv.gz, then builds whole_genome_SNVs_chr.tsv.gz (+.tbi)
# exactly like step 6 of download_references.sh (contigs 1 -> chr1). No downloads. Log: ~/cadd_snv.log
set -uo pipefail
REF=${1:-/data/raredisease/references/grch38}; T=${2:-4}; cd "$REF/vcfanno" || exit 1
SNV=whole_genome_SNVs.tsv.gz; OUT=whole_genome_SNVs_chr.tsv.gz; SIZE=87473403655
log() { echo "$(date '+%F %T') $*"; }
log "waiting for $SNV"
until [ "$(stat -c %s $SNV 2>/dev/null)" = "$SIZE" ] && [ ! -e $SNV.aria2 ]; do sleep 300; done
log "download complete, checking gzip integrity"
gzip -t $SNV || { log "!! $SNV is corrupt, NOT processing"; exit 1; }
log "adding chr prefix"
zcat $SNV | awk 'BEGIN{OFS="\t"} /^#/ {print; next} {print "chr"$0}' | bgzip -@ "$T" > $OUT.part && mv $OUT.part $OUT || { log "!! failed"; exit 1; }
tabix -f -s 1 -b 2 -e 2 -c '#' $OUT && log "indexed"
tabix $OUT chr17:7675088-7675088 | head -3
[ -s $OUT.tbi ] && rm $SNV && log "DONE, raw file removed"
