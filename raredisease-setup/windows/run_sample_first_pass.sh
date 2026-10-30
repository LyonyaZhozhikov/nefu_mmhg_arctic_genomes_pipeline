#!/usr/bin/env bash
# Singleton WGS run of nf-core/raredisease 3.1.2, first pass (no CADD, no SpliceAI; ClinVar on).
# Usage: bash run_sample_first_pass.sh <fastq_dir with *_R1.fq.gz/*_R2.fq.gz and .md5> <sample_id> [sex 0/1/2] [phenotype 1/2] [platform]
# Copies the FASTQ to /data (NVMe), checks md5, writes samplesheet + params, runs with -resume.
# Later full pass (CADD + SpliceAI ready): same command line with params.yaml from params_grch38_wgs.yaml and
# without -c conf/first_pass.config, still -resume: alignment and calling stay cached.
set -euo pipefail
SRC=${1:?fastq dir}; ID=${2:?sample id}; SEX=${3:-0}; PHENO=${4:-2}; PLATFORM=${5:-DNBSEQ}
SETUP=$HOME/raredisease-setup; REF=/data/raredisease/references/grch38
RUN=/data/raredisease/runs/$ID; mkdir -p "$RUN/fastq"; cd "$RUN"

R1=$(ls "$SRC"/*_R1.f*q.gz); R2=$(ls "$SRC"/*_R2.f*q.gz)
for f in "$R1" "$R2"; do
  b=$(basename "$f")
  [ "$(stat -c %s "$f")" = "$(stat -c %s fastq/$b 2>/dev/null || echo 0)" ] || { echo "copy $b"; cp "$f" fastq/; }
done
if [ ! -e fastq/md5.ok ] && ls "$SRC"/*.md5 >/dev/null 2>&1; then
  echo "md5 check"; (cd fastq && cat "$SRC"/*.md5 | md5sum -c - ) && touch fastq/md5.ok
fi

cat > samplesheet.csv <<EOF
sample,lane,fastq_1,fastq_2,sex,phenotype,paternal_id,maternal_id,case_id
$ID,1,$RUN/fastq/$(basename "$R1"),$RUN/fastq/$(basename "$R2"),$SEX,$PHENO,0,0,case_$ID
EOF

# params: the lab defaults with this run's paths and the first-pass reference lists
sed -e "s#^input: .*#input:  \"$RUN/samplesheet.csv\"#" \
    -e "s#^outdir: .*#outdir: \"$RUN/results\"#" \
    -e "s#^platform: .*#platform:          \"$PLATFORM\"#" \
    -e "s#vep_files.csv\"#vep_files_first_pass.csv\"#" \
    -e "s#vcfanno_config_grch38_yakut.toml\"#vcfanno_config_grch38_yakut_nocadd.toml\"#" \
    -e "s#vcfanno_resources.txt\"#vcfanno_resources_nocadd.txt\"#" \
    -e "/^cadd_resources:/d" -e "/^cadd_prescored:/d" \
    -e "s#rank_model_snv_grch38_nocohort.ini\"#rank_model_snv_grch38_nocohort_nocadd.ini\"#" \
    "$SETUP/params_grch38_wgs.yaml" > params_first_pass.yaml
# reuse the bwa-mem2 index once a first run has saved it
BW=$(ls -d /data/raredisease/runs/*/results/references/bwamem2 2>/dev/null | head -1 || true)
[ -n "$BW" ] && sed -i -e "s#^save_reference: .*#save_reference: false#" -e "s#^\# bwamem2: .*#bwamem2: \"$BW\"#" params_first_pass.yaml

nextflow run nf-core/raredisease -r 3.1.2 -profile docker \
  -c "$SETUP/conf/local.config" -c "$SETUP/conf/first_pass.config" \
  -params-file params_first_pass.yaml -ansi-log false -resume 2>&1 | tee -a run.log
