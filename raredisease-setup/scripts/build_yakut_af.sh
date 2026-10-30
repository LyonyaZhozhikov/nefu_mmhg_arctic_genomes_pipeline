#!/usr/bin/env bash
# Build the in-house Yakut allele-frequency VCF (YAKUT_AF etc.) from DeepVariant gVCFs.
#
# Who to include: one set of UNRELATED individuals, ideally the unaffected parents (founders) of trios plus
# unrelated singletons. Do not include several members of one family: shared haplotypes inflate AF.
# Remove sample duplicates and anyone failing QC (contamination, sex mismatch) first.
#
# Usage: bash build_yakut_af.sh founders_gvcfs.txt <reference.fna> <out_dir> [threads] [mem_gb]
#   founders_gvcfs.txt: one absolute path per line to <sample>_deepvar.g.vcf.gz (results/deepvariant_gvcf/)
# Needs: glnexus_cli, bcftools, tabix.
#   The pipeline's own image has both tools:
#   docker run --rm -u $(id -u):$(id -g) -v /data:/data community.wave.seqera.io/library/bcftools_glnexus:cf380f1a6410f606 bash build_yakut_af.sh ...
set -euo pipefail
LIST=${1:?list of gVCFs}; FA=${2:?reference fasta}; OUT=${3:?out dir}; T=${4:-16}; MEM=${5:-64}
mkdir -p "$OUT"; cd "$OUT"
N=$(grep -c . "$LIST"); echo "joint-genotyping $N founders"
rm -rf GLnexus.DB
glnexus_cli --config DeepVariant_unfiltered --threads "$T" --mem-gbytes "$MEM" --list "$LIST" > yakut_cohort.bcf
# Split multiallelics, left-normalise, compute AF/AC/AN/AC_Hom, drop genotypes -> sites-only file
bcftools norm -m -both -f "$FA" --threads "$T" yakut_cohort.bcf -Ou \
 | bcftools view -i 'ALT!="*"' -Ou \
 | bcftools +fill-tags -Ou -- -t AF,AC,AN,AC_Hom \
 | bcftools view -G -i 'AC>0' -Ou \
 | bcftools annotate -x '^INFO/AF,INFO/AC,INFO/AN,INFO/AC_Hom' -Oz -o yakut_cohort_af.vcf.gz --threads "$T"
tabix -f -p vcf yakut_cohort_af.vcf.gz
echo "$N founders, $(date +%F)" > yakut_cohort_af.README
bcftools view -H yakut_cohort_af.vcf.gz | wc -l | xargs echo "sites:"
echo "Copy yakut_cohort_af.vcf.gz(.tbi) to <REF>/vcfanno/ (same name as in vcfanno_resources.txt). Keep the multi-sample"
echo "yakut_cohort.bcf too: it is what you re-use for ROH, PCA/relatedness and carrier-frequency studies."
# Tip: also export a tab file in the --gnomad_af format to give bcftools roh Yakut frequencies:
#   bcftools query -f '%CHROM\t%POS\t%REF,%ALT\t%AF\n' yakut_cohort_af.vcf.gz | bgzip > yakut_af.tab.gz && tabix -s1 -b2 -e2 yakut_af.tab.gz
