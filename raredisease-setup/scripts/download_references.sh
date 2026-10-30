#!/usr/bin/env bash
# Download and prepare GRCh38 references for nf-core/raredisease 3.1.2 (WGS).
# Usage:  bash download_references.sh /data/raredisease/references/grch38
# Needs: wget, samtools, bcftools, tabix/bgzip (htslib), git. Run inside `conda activate` env or a tools container.
# Each step is skipped when its output already exists, so the script can be re-run after an interruption.
# Expect roughly 250-350 GB in total (CADD ~85 GB + ~220 GB annotations, gnomAD per-chromosome VCFs are
# downloaded one at a time, stripped to a few fields, and deleted).
set -euo pipefail
REF=${1:?give the target directory, e.g. /data/raredisease/references/grch38}
SETUP=$(cd "$(dirname "$0")/.." && pwd)        # the raredisease-setup folder
THREADS=${THREADS:-8}
# PART=small skips the two big downloads (gnomAD v4.1 genomes and CADD, ~300 GB together); run again
# without PART later to fetch them. Everything else (~30-40 GB) is downloaded in both modes.
PART=${PART:-all}
mkdir -p "$REF"/{vcfanno,svdb,vep_plugin_files,verifybamid,cadd_prescored}
cd "$REF"
# Only one copy at a time: two runs writing the same wget -c file corrupt it
exec 9>"$REF/.download.lock"
flock -n 9 || { echo "Другая загрузка уже идёт в $REF (tmux attach -t refs). Выход."; exit 1; }

step() { echo -e "\n== $*"; }

step "1. GRCh38 no-alt analysis set (chr1-22,X,Y,M first; recommended for short-read callers)"
FA=GCA_000001405.15_GRCh38_no_alt_analysis_set.fna
if [ ! -s "$FA" ]; then
  wget -c https://ftp.ncbi.nlm.nih.gov/genomes/all/GCA/000/001/405/GCA_000001405.15_GRCh38/seqs_for_alignment_pipelines.ucsc_ids/$FA.gz
  gunzip "$FA.gz"
fi
[ -s "$FA.fai" ] || samtools faidx "$FA"
[ -s "${FA%.fna}.dict" ] || samtools dict "$FA" -o "${FA%.fna}.dict"
head -25 "$FA.fai" | cut -f1 | tr '\n' ' '; echo   # must print chr1..chr22 chrX chrY chrM
bash "$SETUP/scripts/make_interval_lists.sh" "${FA%.fna}.dict" "$REF"

step "2. Files shipped in raredisease-setup/references (rank models, catalogs, regions)"
for f in variant_catalog_grch38.json rank_model_snv_grch38_yakut.ini rank_model_sv_grch38_yakut.ini \
         variant_consequences_v2.txt reduced_penetrance_grch38.tsv grch38_par.bed \
         grch38_manta_call_regions_-1.0-.bed.gz grch38_manta_call_regions_-1.0-.bed.gz.tbi \
         grch38_alu.bed grch38_herv.bed grch38_l1.bed grch38_sva.bed \
         vcfanno_config_grch38_yakut.toml vcfanno_resources.txt svdb_query_dbs.csv svdb_query_dbs_with_yakut.csv vep_files.csv vep_files_extended.csv \
         mobile_element_references.tsv; do
  [ -e "$f" ] || cp "$SETUP/references/$f" .
done

step "3. VEP 110 merged cache + plugins (the pipeline runs VEP 110.1 with --merged)"
if [ ! -d vep_cache/homo_sapiens_merged/110_GRCh38 ]; then
  mkdir -p vep_cache && cd vep_cache
  VEP_TGZ=homo_sapiens_merged_vep_110_GRCh38.tar.gz
  wget -c https://ftp.ensembl.org/pub/release-110/variation/indexed_vep_cache/$VEP_TGZ
  # Check the archive before unpacking; a broken one is deleted so the next run downloads it again
  if ! gzip -t "$VEP_TGZ"; then echo "!! $VEP_TGZ повреждён, удаляю. Запустите скрипт снова."; rm -f "$VEP_TGZ"; exit 1; fi
  tar xzf "$VEP_TGZ" && rm "$VEP_TGZ"
  cd "$REF"
fi
if [ ! -d vep_cache/Plugins ]; then
  git clone --depth 1 -b release/110 https://github.com/Ensembl/VEP_plugins.git vep_cache/Plugins
fi
cp -n vep_cache/Plugins/LoFtool_scores.txt vep_plugin_files/ 2>/dev/null || echo "!! LoFtool_scores.txt not found in VEP_plugins; get it from the LoFtool.pm header"
cp -n vep_cache/Plugins/pLI_values.txt     vep_plugin_files/ 2>/dev/null || echo "!! pLI_values.txt not found in VEP_plugins; build it as described in the pLI.pm header"

if [ "$PART" = all ] && [ -s vcfanno/gnomad.genomes.v4.1.sites.af_only.vcf.gz.tbi ] && [ -s gnomad_v4.1_genomes_af.tab.gz.tbi ]; then
step "4. gnomAD v4.1 genomes: already built"
elif [ "$PART" = all ]; then
step "4. gnomAD v4.1 genomes -> small AF-only VCF for vcfanno + tab file for bcftools roh"
bash "$SETUP/scripts/make_gnomad_af.sh" "$REF/vcfanno" "$THREADS"
else
step "4. gnomAD v4.1 genomes: skipped (PART=$PART)"
fi

step "5. gnomAD mitochondrial v3.1"
MT=vcfanno/gnomad.genomes.v3.1.sites.chrM.af_only.vcf.gz
if [ ! -s "$MT" ]; then
  wget -c -O vcfanno/gnomad_chrM.vcf.bgz https://storage.googleapis.com/gcp-public-data--gnomad/release/3.1/vcf/genomes/gnomad.genomes.v3.1.sites.chrM.vcf.bgz
  bcftools annotate -x '^INFO/AF_hom,INFO/AF_het,INFO/mitotip_score,INFO/mitotip_trna_prediction' \
      vcfanno/gnomad_chrM.vcf.bgz -Oz -o "$MT" && tabix -p vcf "$MT" && rm vcfanno/gnomad_chrM.vcf.bgz
fi

if [ "$PART" != all ]; then
step "6. CADD v1.7: skipped (PART=$PART)"
else
step "6. CADD v1.7 (SNV scores for vcfanno, annotations for indel scoring)"
fi
# BIG_DIR: folder with files from windows/download_big_files.ps1 (e.g. /mnt/e/raredisease_big on an
# external disk). Files found there are read in place and never deleted; missing ones are downloaded.
CADD_URL=https://kircherlab.bihealth.org/download/CADD/v1.7/GRCh38
if [ "$PART" = all ] && [ ! -s vcfanno/whole_genome_SNVs_chr.tsv.gz ]; then
  SNV=vcfanno/whole_genome_SNVs.tsv.gz
  if [ -n "${BIG_DIR:-}" ] && [ -e "$BIG_DIR/cadd/whole_genome_SNVs.tsv.gz.done" ]; then SNV=$BIG_DIR/cadd/whole_genome_SNVs.tsv.gz
  else wget -c -O "$SNV" $CADD_URL/whole_genome_SNVs.tsv.gz; fi
  # CADD uses 1,2,..; the reference uses chr1,chr2,.. -> add the prefix so vcfanno matches contigs
  zcat "$SNV" | awk 'BEGIN{OFS="\t"} /^#/ {print; next} {print "chr"$0}' \
      | bgzip -@ "$THREADS" > vcfanno/whole_genome_SNVs_chr.tsv.gz
  tabix -s 1 -b 2 -e 2 -c '#' vcfanno/whole_genome_SNVs_chr.tsv.gz
  if [ "$SNV" = vcfanno/whole_genome_SNVs.tsv.gz ]; then rm "$SNV"; fi
fi
if [ "$PART" = all ] && [ ! -d cadd_annotations ]; then
  ANNO=GRCh38_v1.7.tar.gz
  if [ -n "${BIG_DIR:-}" ] && [ -e "$BIG_DIR/cadd/GRCh38_v1.7.tar.gz.done" ]; then ANNO=$BIG_DIR/cadd/GRCh38_v1.7.tar.gz
  else wget -c $CADD_URL/GRCh38_v1.7.tar.gz; fi
  mkdir -p cadd_annotations && tar xzf "$ANNO" -C cadd_annotations
  if [ "$ANNO" = GRCh38_v1.7.tar.gz ]; then rm "$ANNO"; fi
  echo "   check that cadd_annotations/ now contains the GRCh38_v1.7 folder the pipeline expects (docs/usage.md)"
fi

step "7. gnomAD SV v4.1 for SVDB"
[ -s svdb/gnomad.v4.1.sv.sites.vcf.gz ] || wget -c -O svdb/gnomad.v4.1.sv.sites.vcf.gz \
    https://storage.googleapis.com/gcp-public-data--gnomad/release/4.1/genome_sv/gnomad.v4.1.sv.sites.vcf.gz
# SVDB aborts (and the pipeline silently gets 0 SVs) if any db record lacks AF/AC: drop the 721 multiallelic CNVs
[ -s svdb/gnomad.v4.1.sv.sites.af.vcf.gz.tbi ] || { bcftools view -e 'INFO/AF="." || INFO/AC="."' svdb/gnomad.v4.1.sv.sites.vcf.gz \
    -Oz -o svdb/gnomad.v4.1.sv.sites.af.vcf.gz && tabix -f -p vcf svdb/gnomad.v4.1.sv.sites.af.vcf.gz; }

step "8. ClinVar (GRCh38), contigs renamed to chr*"
if [ ! -s vep_plugin_files/clinvar_chr.vcf.gz ]; then
  # no -c: ClinVar is replaced weekly, resuming would glue a new file onto an old one
  wget -O vep_plugin_files/clinvar.vcf.gz https://ftp.ncbi.nlm.nih.gov/pub/clinvar/vcf_GRCh38/clinvar.vcf.gz
  for c in $(seq 1 22) X Y; do echo -e "$c\tchr$c"; done > chr_rename.txt; echo -e "MT\tchrM" >> chr_rename.txt
  # ClinVar's header has no ##contig lines; the index supplies them, otherwise --rename-chrs fails
  tabix -f -p vcf vep_plugin_files/clinvar.vcf.gz
  bcftools annotate --rename-chrs chr_rename.txt vep_plugin_files/clinvar.vcf.gz -Oz -o vep_plugin_files/clinvar_chr.vcf.gz
  tabix -p vcf vep_plugin_files/clinvar_chr.vcf.gz && rm vep_plugin_files/clinvar.vcf.gz vep_plugin_files/clinvar.vcf.gz.tbi
fi

step "9. VerifyBamID2 contamination panel (optional)"
for e in UD mu bed; do
  [ -s verifybamid/1000g.phase3.100k.b38.vcf.gz.dat.$e ] || wget -q -O verifybamid/1000g.phase3.100k.b38.vcf.gz.dat.$e \
     https://raw.githubusercontent.com/Griffan/VerifyBamID/master/resource/1000g.phase3.100k.b38.vcf.gz.dat.$e
done

step "10. Empty Yakut placeholders until the cohort databases exist (run_vcfanno_db_sanity_check drops them)"
if [ ! -s vcfanno/yakut_cohort_af.vcf.gz ]; then
  { echo '##fileformat=VCFv4.2'
    echo '##INFO=<ID=AF,Number=A,Type=Float,Description="Yakut cohort AF">'
    echo '##INFO=<ID=AC,Number=A,Type=Integer,Description="Yakut cohort AC">'
    echo '##INFO=<ID=AN,Number=1,Type=Integer,Description="Yakut cohort AN">'
    echo '##INFO=<ID=AC_Hom,Number=A,Type=Integer,Description="Yakut cohort homozygous AC">'
    cut -f1,2 "$FA.fai" | head -25 | awk '{print "##contig=<ID="$1",length="$2">"}'
    echo -e '#CHROM\tPOS\tID\tREF\tALT\tQUAL\tFILTER\tINFO'; } | bgzip > vcfanno/yakut_cohort_af.vcf.gz
  tabix -p vcf vcfanno/yakut_cohort_af.vcf.gz
fi
if [ ! -s svdb/yakut_cohort_svdb.vcf ]; then
  echo "   NOTE: svdb_query_dbs.csv uses gnomAD SV only; switch to svdb_query_dbs_with_yakut.csv after build_yakut_svdb.sh"
fi

cat <<'MANUAL'

== Manual downloads (need registration or a licence choice)
 * SpliceAI precomputed scores (Illumina BaseSpace, free login): spliceai_scores.raw.snv.hg38.vcf.gz (+.tbi).
   Save as vep_plugin_files/spliceai_21_scores_raw_snv_-v1.3-.vcf.gz (+.tbi): the pipeline's VEP command uses that exact name.
 * dbNSFP 4.9a (academic licence) for conf/vep_extended.config: build dbNSFP4.9a_grch38.gz as the dbNSFP.pm header describes,
   put it in vep_plugin_files/.
Then fix every path in vcfanno_resources.txt, svdb_query_dbs.csv, vep_files.csv, mobile_element_references.tsv
if your REF directory is not /data/raredisease/references/grch38.
MANUAL
