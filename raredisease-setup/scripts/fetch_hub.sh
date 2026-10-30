#!/usr/bin/env bash
# One place for every big raw download of nf-core/raredisease 3.1.2 (GRCh38 WGS) references.
# Only downloads (resumable, wget -c); download_references.sh later finds the files in place and processes them.
# Usage:
#   bash fetch_hub.sh REF status          table: done / partial / missing for every file
#   bash fetch_hub.sh REF gnomad [N]      gnomAD v4.1 genomes chr1-22,X,Y (Google storage, works WITHOUT VPN), N parallel (default 3)
#   bash fetch_hub.sh REF vpn             Ensembl VEP cache + CADD SNV + CADD annotations (need VPN)
#   bash fetch_hub.sh REF import DIR      copy finished and partial files from the home drive (DIR = .../ngs_offline)
# REF is the references folder, e.g. /data/raredisease/references/grch38
set -uo pipefail
REF=${1:?REF}; CMD=${2:?command}; cd "$REF" || exit 1
W="wget -c --timeout=60 --tries=0 --waitretry=10 --retry-connrefused --progress=dot:giga"
GN=https://storage.googleapis.com/gcp-public-data--gnomad/release/4.1/vcf/genomes
declare -A GS=([1]=44078103205 [2]=46559034968 [3]=39251922328 [4]=36033143211 [5]=32707176660 [6]=31788224183
 [7]=31250828580 [8]=29291764214 [9]=24761070444 [10]=26841421792 [11]=26393279310 [12]=25950974228 [13]=17100492651
 [14]=17860683682 [15]=16904431253 [16]=18918703003 [17]=17412317144 [18]=14430177524 [19]=13679473477 [20]=11838569571
 [21]=7758981978 [22]=8731339280 [X]=22908335319 [Y]=599108494)
# CHR="1 2 3" bash fetch_hub.sh REF gnomad  limits the chromosomes (e.g. when another PC fetches the rest)
CHR=${CHR:-"1 2 3 4 5 6 7 8 9 10 11 12 13 14 15 16 17 18 19 20 21 22 X Y"}
# path | expected bytes (0 = unknown) | url | output that means "already processed"
# CADD annotations: the file is GRCh38_v1.7.tar.gz in REF (annotationsGRCh38_v1.7.tar.gz is 404), as download_references.sh expects
OTHER=(
 "vep_cache/homo_sapiens_merged_vep_110_GRCh38.tar.gz|0|https://ftp.ensembl.org/pub/release-110/variation/indexed_vep_cache/homo_sapiens_merged_vep_110_GRCh38.tar.gz|vep_cache/homo_sapiens_merged/110_GRCh38"
 "vcfanno/whole_genome_SNVs.tsv.gz|0|https://kircherlab.bihealth.org/download/CADD/v1.7/GRCh38/whole_genome_SNVs.tsv.gz|vcfanno/whole_genome_SNVs_chr.tsv.gz"
 "GRCh38_v1.7.tar.gz|0|https://kircherlab.bihealth.org/download/CADD/v1.7/GRCh38/GRCh38_v1.7.tar.gz|cadd_annotations"
)
gb() { awk -v b="$1" 'BEGIN{printf "%.1f", b/1073741824}'; }
size() { stat -c %s "$1" 2>/dev/null || echo 0; }
gnomad_processed() { [ -s vcfanno/gnomad_v4.1_chr$1.af_only.bcf ] || [ -s vcfanno/gnomad.genomes.v4.1.sites.af_only.vcf.gz ]; }

get_chr() {  # one gnomAD chromosome, verified by size
  c=$1; f=vcfanno/tmp_chr$c.vcf.bgz
  gnomad_processed "$c" && return 0
  [ "$(size $f)" = "${GS[$c]}" ] && return 0
  $W -O "$f" "$GN/gnomad.genomes.v4.1.sites.chr$c.vcf.bgz" -a "logs/chr$c.log"
  [ "$(size $f)" = "${GS[$c]}" ] && echo "chr$c OK" || { echo "chr$c INCOMPLETE ($(gb $(size $f)) GB), run again"; return 1; }
}

case $CMD in
status)
  printf "%-55s %8s %8s  %s\n" FILE HAVE_GB NEED_GB STATE
  for c in $CHR; do f=vcfanno/tmp_chr$c.vcf.bgz; h=$(size $f)
    if gnomad_processed $c; then s=processed; elif [ "$h" = "${GS[$c]}" ]; then s=done; elif [ "$h" -gt 0 ]; then s=partial; else s=missing; fi
    printf "%-55s %8s %8s  %s\n" "$f" "$(gb $h)" "$(gb ${GS[$c]})" "$s"; done
  for e in "${OTHER[@]}"; do IFS='|' read -r p b u out <<<"$e"; h=$(size "$p")
    if [ -e "$out" ]; then s=processed; elif [ -e "$p.aria2" ]; then s="partial (aria2c running or stopped)"; elif [ "$h" -gt 0 ]; then s="present (size unknown: rerun vpn to finish/verify)"; else s=missing; fi
    printf "%-55s %8s %8s  %s\n" "$p" "$(gb $h)" "?" "$s"; done ;;
gnomad)
  mkdir -p vcfanno logs; echo "progress: tail -f $REF/logs/chrN.log"; export -f get_chr gnomad_processed size gb; export W GN; export GS_DUMP="$(declare -p GS)"
  echo $CHR | tr ' ' '\n' | xargs -P "${3:-3}" -I{} bash -c 'eval "$GS_DUMP"; get_chr {}' ;;
vpn)
  for e in "${OTHER[@]}"; do IFS='|' read -r p b u out <<<"$e"
    [ -e "$out" ] && { echo "processed: $p"; continue; }
    mkdir -p "$(dirname "$p")" logs; echo "== $p"
    # Through the VPN one connection gets ~0.2 MB/s, 16 connections ~16x that: use aria2c when installed.
    # -c continues a file started by wget; the .aria2 file next to it means "not finished yet".
    if command -v aria2c >/dev/null; then
      aria2c -c -x16 -s16 -k20M --file-allocation=none --max-tries=0 --retry-wait=10 --timeout=60 --summary-interval=60 \
        --console-log-level=warn -d "$(dirname "$p")" -o "$(basename "$p")" "$u" 2>&1 | tee -a "logs/$(basename "$p").log" \
        && [ ! -e "$p.aria2" ] || echo "!! $p failed, run again"
    else $W -O "$p" "$u" || echo "!! $p failed, run again"; fi; done ;;
import)
  SRC=${3:?home drive folder, e.g. /mnt/e/ngs_offline}/grch38
  # vep_cache is skipped: the work copy is downloaded separately. --append resumes partial files, never shrinks bigger ones.
  # The genome .fna.gz is skipped when the unpacked .fna is already here.
  EX=(--exclude 'vep_cache/'); [ -s GCA_000001405.15_GRCh38_no_alt_analysis_set.fna ] && EX+=(--exclude 'GCA_000001405.15_GRCh38_no_alt_analysis_set.fna.gz')
  rsync -ah --info=progress2 --append "${EX[@]}" "$SRC/" "$REF/" ;;
*) echo "unknown command $CMD"; exit 1 ;;
esac
