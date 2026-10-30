#!/usr/bin/env bash
# Build an in-house Yakut SV frequency database with SVDB (same tool the pipeline uses to query).
# Input: the per-case SV VCFs from results/call_sv/genome/<case>_sv_merge.vcf.gz of UNRELATED founders
#        (extract one founder per family first with bcftools view -s <sample>), one path per line.
# Usage: bash build_yakut_svdb.sh founders_sv_vcfs.txt <out_dir>
# Needs: svdb (pip install svdb, or the biocontainers svdb image), bcftools.
set -euo pipefail
LIST=${1:?list of SV VCFs}; OUT=${2:?out dir}; mkdir -p "$OUT"; cd "$OUT"
svdb --build --files $(cat "$LIST" | tr '\n' ' ') --prefix yakut_cohort_svdb
svdb --export --db yakut_cohort_svdb.db --prefix yakut_cohort_svdb
ls -l yakut_cohort_svdb*.vcf
echo "Copy yakut_cohort_svdb.vcf to <REF>/svdb/ ; svdb_query_dbs.csv already maps FRQ/OCC -> yakut_svAF/yakut_svOCC"
