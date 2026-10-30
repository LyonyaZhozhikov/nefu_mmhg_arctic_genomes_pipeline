#!/usr/bin/env bash
# Preliminary, human-readable tables from a running/finished raredisease outdir (read-only on the run).
# Usage: bash export_preliminary.sh <results dir> <sample id> <out dir (e.g. /mnt/c/.../results_X)>
set -uo pipefail
R=${1:?results}; ID=${2:?sample}; OUT=${3:?outdir}; mkdir -p "$OUT"; cd "$R"

# --- QC summary
{
  echo -e "metric\tvalue"
  awk -F'\t' '/^CATEGORY/{for(i=1;i<=NF;i++)h[i]=$i; next} $1=="PAIR"{for(i=1;i<=NF;i++) if(h[i]~/^(TOTAL_READS|PCT_PF_READS_ALIGNED|PCT_CHIMERAS|MEAN_READ_LENGTH)$/) print h[i]"\t"$i}' qc_bam/*alignment_summary_metrics
  awk -F'\t' '/^LIBRARY/{for(i=1;i<=NF;i++)h[i]=$i; getline; for(i=1;i<=NF;i++) if(h[i]=="PERCENT_DUPLICATION") print h[i]"\t"$i}' alignment/*metrics.txt
  awk -F'\t' '/^MEDIAN_INSERT_SIZE/{getline; print "MEDIAN_INSERT_SIZE\t"$1}' qc_bam/*insert_size_metrics
  grep -E "^(total|chr1|chrX|chrY|chrM)\s" qc_bam/*mosdepth.summary.txt | awk -F'\t' '{print "mean_coverage_"$1"\t"$4}'
  awk 'NR==2{print "inferred_sex (ngs-bits)\t"$2; print "chrY/chrX_read_ratio\t"$5}' ngsbits_samplegender/*
} > "$OUT/01_QC_summary.tsv"
# share of genome at >=10x/20x/30x
awk -F'\t' '$1=="total" && ($2==10||$2==20||$2==30){print "pct_genome_>="$2"x\t"$3}' qc_bam/*mosdepth.global.dist.txt >> "$OUT/01_QC_summary.tsv"
cp trimming/*.fastp.html "$OUT/02_fastp_report.html" 2>/dev/null
for f in fastqc/*/*_fastqc.html; do cp "$f" "$OUT/03_$(basename "$f")"; done 2>/dev/null

# --- repeat expansions (ExpansionHunter + Stranger), sorted: abnormal first
STR=$(ls repeat_expansions/*_stranger.vcf.gz 2>/dev/null | head -1)
if [ -n "$STR" ]; then
  { echo -e "locus\tgene_HGNC\tdisease\tinheritance\trepeat_unit\tgenotype_repeats\tCI\tstatus\tnormal_max\tpathologic_min\tchrom\tpos"
    bcftools query -f '%REPID\t%HGNCId\t%Disease\t%InheritanceMode\t%DisplayRU\t[%REPCN]\t[%REPCI]\t%STR_STATUS\t%STR_NORMAL_MAX\t%STR_PATHOLOGIC_MIN\t%CHROM\t%POS\n' "$STR" \
      | awk -F'\t' 'BEGIN{OFS="\t"} {o=($8~/full_mutation/)?0:($8~/pre_mutation/)?1:2; print o,$0}' | sort -t$'\t' -k1,1n -k2,2 | cut -f2-
  } > "$OUT/04_repeat_expansions.tsv"
fi

# --- SMN1/SMN2 copy number (SMA)
cp smncopynumbercaller/out/*.tsv "$OUT/05_SMN_copy_number.tsv" 2>/dev/null

# --- mitochondrial deletions (MitoSAlt / eKLIPse summary)
cp call_sv/*mitochondria_deletions.txt "$OUT/06_mito_deletions.txt" 2>/dev/null

# --- structural variants: counts and list (raw caller merge; final ranked SVs come later)
SV=$(ls call_sv/case_*_sv.vcf.gz 2>/dev/null | head -1)
if [ -n "$SV" ]; then
  { echo -e "SVTYPE\tcount\tcount_>=50kb"
    bcftools query -f '%SVTYPE\t%INFO/SVLEN\n' "$SV" | awk -F'\t' '{l=$2<0?-$2:$2; n[$1]++; if(l>=50000) b[$1]++} END{for(t in n) print t"\t"n[t]"\t"b[t]+0}' | sort; } > "$OUT/07_SV_counts.tsv"
  { echo -e "chrom\tstart\tend\tSVTYPE\tSVLEN\tcallers\tFILTER\tGT"
    bcftools query -f '%CHROM\t%POS\t%INFO/END\t%SVTYPE\t%INFO/SVLEN\t%INFO/set\t%FILTER\t[%GT]\n' "$SV"; } > "$OUT/08_SV_calls_raw.tsv"
fi

# --- SNVs (only when the pipeline has published them)
SNV=$(ls rank_and_filter/*snv*research*.vcf.gz annotate_snv/genome/*vep*.vcf.gz call_snv/genome/*.vcf.gz 2>/dev/null | head -1)
if [ -n "$SNV" ]; then
  bcftools stats "$SNV" | grep "^SN" | cut -f3- > "$OUT/09_SNV_stats.tsv"
fi
ls -la "$OUT"
