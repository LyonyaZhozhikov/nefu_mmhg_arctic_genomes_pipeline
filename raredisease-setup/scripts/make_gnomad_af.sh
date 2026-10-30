#!/usr/bin/env bash
# gnomAD v4.1 genomes -> (a) small sites VCF for vcfanno, (b) tab file for --gnomad_af (bcftools roh / UPD).
# Downloads one chromosome at a time (~5-70 GB each), keeps only the needed INFO fields, then deletes it.
# Usage: bash make_gnomad_af.sh <outdir> [threads]
set -euo pipefail
OUT=${1:?outdir}; T=${2:-8}; cd "$OUT"
BASE=https://storage.googleapis.com/gcp-public-data--gnomad/release/4.1/vcf/genomes
KEEP='^INFO/AF,INFO/AF_grpmax,INFO/AC,INFO/nhomalt,INFO/AF_eas'
for c in $(seq 1 22) X Y; do
  part=gnomad_v4.1_chr$c.af_only.bcf
  [ -s "$part" ] && continue
  # BIG_DIR (see download_references.sh): use a pre-downloaded file in place instead of downloading
  src=${BIG_DIR:-/nonexistent}/gnomad/gnomad.genomes.v4.1.sites.chr$c.vcf.bgz
  if [ -e "$src.done" ]; then tmp=$src
  else tmp=tmp_chr$c.vcf.bgz; wget -c -q -O "$tmp" $BASE/gnomad.genomes.v4.1.sites.chr$c.vcf.bgz; fi
  bcftools view -f PASS --threads "$T" "$tmp" \
   | bcftools annotate -x "$KEEP" --threads "$T" -Ob -o "$part"
  if [ "$tmp" = tmp_chr$c.vcf.bgz ]; then rm "$tmp"; fi; echo "chr$c done"
done
bcftools concat --threads "$T" -Oz -o gnomad.genomes.v4.1.sites.af_only.vcf.gz gnomad_v4.1_chr{1..22}.af_only.bcf gnomad_v4.1_chrX.af_only.bcf gnomad_v4.1_chrY.af_only.bcf
tabix -p vcf gnomad.genomes.v4.1.sites.af_only.vcf.gz
# Tab file: CHROM POS REF,ALT AF (no header), as the pipeline docs specify for --gnomad_af
bcftools query -f '%CHROM\t%POS\t%REF,%ALT\t%AF\n' gnomad.genomes.v4.1.sites.af_only.vcf.gz \
 | awk '$4 != "." ' | bgzip -@ "$T" > ../gnomad_v4.1_genomes_af.tab.gz
tabix -s1 -b2 -e2 ../gnomad_v4.1_genomes_af.tab.gz
rm gnomad_v4.1_chr*.af_only.bcf
