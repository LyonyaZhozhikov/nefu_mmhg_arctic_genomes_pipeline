#!/usr/bin/env bash
# Build the classic bwa index of the GRCh38 no-alt FASTA once, the same way the pipeline's BWA_INDEX_GENOME does
# (same container, prefix = FASTA basename), so params.bwa can point to it and runs skip the 1 h 10 min rebuild.
# Log: ~/bwa_index.log
REF=/data/raredisease/references/grch38
FASTA=GCA_000001405.15_GRCh38_no_alt_analysis_set.fna
IMG=community.wave.seqera.io/library/bwa_htslib_samtools:83b50ff84ead50d0
mkdir -p "$REF/bwa"
echo "start $(TZ=Asia/Yakutsk date '+%F %T')"
docker run --rm -u "$(id -u):$(id -g)" -v "$REF:$REF" -w "$REF" "$IMG" \
    bwa index -p "bwa/${FASTA%.fna}" "$FASTA"
echo "exit $?"
ls -la "$REF/bwa"
echo "end $(TZ=Asia/Yakutsk date '+%F %T')"
