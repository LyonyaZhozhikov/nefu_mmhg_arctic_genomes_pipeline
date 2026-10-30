#!/usr/bin/env bash
# Parallel version of make_gnomad_af.sh for already downloaded gnomAD v4.1 genomes (vcfanno/tmp_chrN.vcf.bgz,
# e.g. from fetch_hub.sh). Same output: gnomad.genomes.v4.1.sites.af_only.vcf.gz (+.tbi) for vcfanno and
# ../gnomad_v4.1_genomes_af.tab.gz (+.tbi) for --gnomad_af. No internet needed.
# Usage: bash make_gnomad_af_parallel.sh <REF>/vcfanno [jobs=8] [threads per job=3]
set -euo pipefail
OUT=${1:?vcfanno dir}; J=${2:-8}; T=${3:-3}; cd "$OUT"
export KEEP='^INFO/AF,INFO/AF_grpmax,INFO/AC,INFO/nhomalt,INFO/AF_eas' T
CHRS="1 2 3 4 5 6 7 8 9 10 11 12 13 14 15 16 17 18 19 20 21 22 X Y"

one() {  # chromosome -> af_only.bcf; the raw file is deleted only after the BCF is complete and indexed
  set -o pipefail; c=$1; tmp=tmp_chr$c.vcf.bgz; part=gnomad_v4.1_chr$c.af_only.bcf
  [ -s "$part" ] && [ -s "$part.csi" ] && { rm -f "$tmp"; echo "chr$c already done"; return 0; }
  [ -s "$tmp" ] || { echo "!! chr$c: $tmp missing"; return 1; }
  echo "$(date +%T) chr$c start"
  bcftools view -f PASS --threads "$T" "$tmp" | bcftools annotate -x "$KEEP" --threads "$T" -Ob -o "$part.part" \
    && bcftools index -f --threads "$T" "$part.part" && mv "$part.part.csi" "$part.csi" && mv "$part.part" "$part" \
    || { echo "!! chr$c FAILED (raw file kept)"; rm -f "$part.part" "$part.part.csi"; return 1; }
  rm "$tmp"; echo "$(date +%T) chr$c done ($(du -h "$part" | cut -f1))"
}
export -f one
# biggest chromosomes first so the long ones don't start last
echo $CHRS | tr ' ' '\n' | while read c; do echo "$(stat -c %s tmp_chr$c.vcf.bgz 2>/dev/null || echo 0) $c"; done \
  | sort -rn | cut -d' ' -f2 | xargs -P "$J" -I{} bash -c 'one {}'

for c in $CHRS; do [ -s gnomad_v4.1_chr$c.af_only.bcf.csi ] || { echo "!! chr$c not done, rerun"; exit 1; }; done
echo "$(date +%T) concat"
bcftools concat --threads 16 -Oz -o gnomad.genomes.v4.1.sites.af_only.vcf.gz.part $(for c in $CHRS; do echo gnomad_v4.1_chr$c.af_only.bcf; done)
mv gnomad.genomes.v4.1.sites.af_only.vcf.gz.part gnomad.genomes.v4.1.sites.af_only.vcf.gz
tabix -f -p vcf gnomad.genomes.v4.1.sites.af_only.vcf.gz
# Tab file: CHROM POS REF,ALT AF (no header), as the pipeline docs specify for --gnomad_af
bcftools query -f '%CHROM\t%POS\t%REF,%ALT\t%AF\n' gnomad.genomes.v4.1.sites.af_only.vcf.gz \
 | awk '$4 != "." ' | bgzip -@ 8 > ../gnomad_v4.1_genomes_af.tab.gz
tabix -f -s1 -b2 -e2 ../gnomad_v4.1_genomes_af.tab.gz
rm gnomad_v4.1_chr*.af_only.bcf gnomad_v4.1_chr*.af_only.bcf.csi
echo "$(date +%T) ALL DONE"; ls -la gnomad.genomes.v4.1.sites.af_only.vcf.gz* ../gnomad_v4.1_genomes_af.tab.gz*
