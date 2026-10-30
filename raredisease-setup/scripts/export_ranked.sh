#!/usr/bin/env bash
# Readable candidate tables from raredisease rank_and_filter/*_ranked_research.vcf.gz (sorted by RankScore).
# Usage: bash export_ranked.sh <results dir> <out dir> [top N SNVs, default 2000]
# One row per variant, VEP fields from the most severe transcript (bcftools +split-vep -s worst).
set -uo pipefail
R=${1:?results}; OUT=${2:?outdir}; TOP=${3:-2000}; mkdir -p "$OUT"; cd "$R/rank_and_filter" || exit 1
rank() { awk -F'\t' 'BEGIN{OFS="\t"} NR==1{print; next} {split($k,a,":"); $k=a[2]; print}' k="$1"; }   # "case:12" -> 12
sortrank() { { IFS= read -r h; echo "$h"; sort -t$'\t' -k"$1","$1"gr; }; }

SNV=$(ls *_snv_ranked_research.vcf.gz 2>/dev/null | head -1)
if [ -n "$SNV" ]; then
  H="chrom\tpos\tref\talt\tGT\tDP\tGQ\tRankScore\tgene\tconsequence\tIMPACT\tHGVSc\tHGVSp\tgnomAD_AF\tgnomAD_grpmax\tgnomAD_nhomalt\tCADD\tSIFT\tPolyPhen\tClinVar_sig\tClinVar_review\tClinVar_disease\tinheritance_models\tcompounds"
  F='%CHROM\t%POS\t%REF\t%ALT\t[%GT]\t[%DP]\t[%GQ]\t%RankScore\t%SYMBOL\t%Consequence\t%IMPACT\t%HGVSc\t%HGVSp\t%GNOMADAF\t%GNOMADAF_grpmax\t%GNOMAD_nhomalt\t%CADD\t%SIFT\t%PolyPhen\t%CLINVAR_CLNSIG\t%CLINVAR_CLNREVSTAT\t%CLINVAR_CLNDN\t%GeneticModels\t%Compounds\n'
  { echo -e "$H"; bcftools +split-vep -s worst -f "$F" "$SNV" 2>/dev/null; } | rank 8 | sortrank 8 | awk -F"\t" 'BEGIN{OFS="\t"} NR>1 && length($24)>300 {n=gsub(/,/,",",$24); $24=substr($24,1,300) "...(" n+1 " total)"} {print}' > /tmp/snv_all.tsv
  head -n $((TOP+1)) /tmp/snv_all.tsv > "$OUT/10_SNV_ranked_top$TOP.tsv"
  # ClinVar pathogenic / likely pathogenic (not "conflicting"), any rank
  awk -F'\t' 'NR==1 || ($20 ~ /athogenic/ && $20 !~ /onflicting/)' /tmp/snv_all.tsv > "$OUT/11_SNV_ClinVar_P_LP.tsv"
  # rare (gnomAD grpmax < 1% or absent) protein-changing / splice, HIGH or MODERATE impact
  awk -F'\t' 'NR==1 || (($15=="." || $15<0.01) && ($11=="HIGH" || $11=="MODERATE"))' /tmp/snv_all.tsv > "$OUT/12_SNV_rare_HIGH_MODERATE.tsv"
  echo "SNV: $(($(wc -l < /tmp/snv_all.tsv)-1)) ranked; ClinVar P/LP $(($(wc -l < "$OUT/11_SNV_ClinVar_P_LP.tsv")-1)); rare HIGH/MODERATE $(($(wc -l < "$OUT/12_SNV_rare_HIGH_MODERATE.tsv")-1))"
  rm -f /tmp/snv_all.tsv
fi

SV=$(ls *_sv_ranked_research.vcf.gz 2>/dev/null | head -1)
if [ -n "$SV" ]; then
  H="chrom\tstart\tend\tSVTYPE\tSVLEN\tGT\tRankScore\tn_genes\tgenes\tworst_consequence\tmost_severe_pLI\tgnomAD_SV_AF\tcallers\tinheritance_models"
  # -d gives one line per transcript; lines of one record are consecutive, so group on a record counte
  # (bcftools query numbers records via the ID-independent key below plus a change test).
  { echo -e "$H"
    bcftools +split-vep -d -f '%CHROM\t%POS\t%INFO/END\t%SVTYPE\t%INFO/SVLEN\t[%GT]\t%RankScore\t%SYMBOL\t%Consequence\t%most_severe_pli\t%gnomad_svAF\t%set\t%GeneticModels\t%ID\n' "$SV" 2>/dev/null \
    | awk -F'\t' 'BEGIN{OFS="\t"; sev["transcript_ablation"]=1; sev["feature_truncation"]=2; sev["stop_lost"]=3; sev["frameshift_variant"]=3; sev["coding_sequence_variant"]=4; sev["exon_loss_variant"]=2}
      function flush(){ if(key=="") return; print f1, ng, (genes==""?".":genes), (wc==""?".":wc), rest }
      { k=$1 FS $2 FS $3 FS $4 FS $14 FS $7
        if(k!=key){ flush(); key=k; genes=""; ng=0; wc=""; wr=99; f1=$1 OFS $2 OFS $3 OFS $4 OFS $5 OFS $6 OFS $7; rest=$10 OFS $11 OFS $12 OFS $13 }
        if($8!="." && index(","genes",", ","$8",")==0){ genes=genes (genes==""?"":",") $8; ng++ }
        split($9,cs,"&"); for(i in cs){ r=(cs[i] in sev)?sev[cs[i]]:50; if(r<wr || wc==""){ if(r<wr){wr=r; wc=cs[i]} } } }
      END{ flush() }'
  } | rank 7 | sortrank 7 > "$OUT/13_SV_ranked.tsv"
  echo "SV: $(($(wc -l < "$OUT/13_SV_ranked.tsv")-1)) ranked"
fi

MT=$(ls *_mt_ranked_research.vcf.gz 2>/dev/null | head -1)
if [ -n "$MT" ]; then
  H="chrom\tpos\tref\talt\tGT\tAF_heteroplasmy\tRankScore\tgene\tconsequence\tHGVSp\tgnomAD_MT_AF_hom\tgnomAD_MT_AF_het\tmitotip\tClinVar_sig\tClinVar_disease"
  { echo -e "$H"; bcftools +split-vep -s worst -f '%CHROM\t%POS\t%REF\t%ALT\t[%GT]\t[%AF]\t%RankScore\t%SYMBOL\t%Consequence\t%HGVSp\t%GNOMAD_MTAF_hom\t%GNOMAD_MTAF_het\t%mitotip_trna_prediction\t%CLINVAR_CLNSIG\t%CLINVAR_CLNDN\n' "$MT" 2>/dev/null; } \
    | rank 7 | sortrank 7 > "$OUT/14_MT_ranked.tsv"
  echo "MT: $(($(wc -l < "$OUT/14_MT_ranked.tsv")-1)) variants"
fi
ls -la "$OUT"
