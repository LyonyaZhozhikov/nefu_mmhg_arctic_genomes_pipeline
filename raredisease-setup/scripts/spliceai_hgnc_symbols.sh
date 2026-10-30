#!/usr/bin/env bash
# Rewrite SpliceAI gene symbols (GENCODE v24, 2016) to the gene names of the VEP cache (Ensembl 110),
# so the VEP SpliceAI plugin (which only reports scores when its SYMBOL equals the VEP gene symbol)
# does not drop renamed genes. Current HGNC (newer than Ensembl 110) only links the names: for an old
# symbol not in Ensembl 110, take the HGNC records naming it (symbol/prev first, alias as fallback),
# and for each record its one name that Ensembl 110 uses (symbol > prev > alias); map only if unique.
set -euo pipefail
REF=${REF:-/data/raredisease/references/grch38}
HGNC=$REF/hgnc/hgnc_complete_set.txt
MAP=$REF/hgnc/spliceai_symbol_map.tsv
IN=$REF/vep_plugin_files/spliceai_masked_cadd_grch38.vcf.gz
OUT=$REF/vep_plugin_files/spliceai_masked_cadd_grch38.hgnc.vcf.gz
TMP=$REF/downloads_scores/spliceai_hgnc_tmp
JOBS=${JOBS:-8}
export IN TMP MAP
mkdir -p "$TMP"
log() { echo "[$(date '+%F %T')] $*"; }

ENS=$REF/hgnc/ensembl110_gene_names.txt
GTF=${GTF:-$REF/cadd_annotations/GRCh38_v1.7/mmsplice/homo_sapiens.110.gtf}
[ -s "$ENS" ] || awk -F'\t' '$3=="gene" && match($9,/gene_name "[^"]+"/) {print substr($9,RSTART+11,RLENGTH-12)}' "$GTF" | sort -u > "$ENS"
log "Ensembl 110 gene names: $(wc -l < "$ENS")"
log "building map from $HGNC"
awk -F'\t' '
  FNR==NR { e[$1]=1; next }
  FNR==1 { for (i=1;i<=NF;i++) c[$i]=i; next }
  $c["status"]=="Approved" {
    r++; s=$c["symbol"]
    p=$c["prev_symbol"];  gsub(/"/,"",p); np=split(p,P,"|")
    q=$c["alias_symbol"]; gsub(/"/,"",q); na=split(q,A,"|")
    # the Ensembl 110 name of this record: symbol, else a unique prev, else a unique alias
    t=""; if (s in e) t=s
    if (t=="") { k=0; for(i=1;i<=np;i++) if(P[i] in e){k++; x=P[i]} if(k==1) t=x }
    if (t=="") { k=0; for(i=1;i<=na;i++) if(A[i] in e){k++; x=A[i]} if(k==1) t=x }
    if (t=="") next
    strong[s]=strong[s] SUBSEP t; for(i=1;i<=np;i++) if(P[i]!="") strong[P[i]]=strong[P[i]] SUBSEP t
    for(i=1;i<=na;i++) if(A[i]!="") weak[A[i]]=weak[A[i]] SUBSEP t
  }
  function uniq(l,   n,a,i,u,k,seen) { n=split(substr(l,2),a,SUBSEP); k=0; for(i=1;i<=n;i++) if(!(a[i] in seen)){seen[a[i]]=1; k++; u=a[i]} return k==1 ? u : "" }
  END {
    for (o in strong) if (!(o in e)) { u=uniq(strong[o]); if (u!="" && u!=o) { print o "\t" u "\tprev"; done[o]=1 } }
    for (o in weak) if (!(o in e) && !(o in strong)) { u=uniq(weak[o]); if (u!="" && u!=o) print o "\t" u "\talias" }
  }' "$ENS" "$HGNC" | sort > "$MAP"
log "map: $(wc -l < "$MAP") entries ($(grep -c 'prev$' "$MAP") prev, $(grep -c 'alias$' "$MAP") alias)"

one_contig() {
  local part="$TMP/$1.vcf.gz"
  [ -s "$part" ] && return 0
  tabix "$IN" "$2" | awk -F'\t' -v OFS='\t' -v stats="$TMP/$1.stats" '
    NR==FNR { m[$1]=$2; next }
    { split($8,f,"|"); s=f[2]; if (s in m) { p=index($8,"|"); r=substr($8,p+1); $8=substr($8,1,p) m[s] substr(r,index(r,"|")); ch[s]++ } print }
    END { for (s in ch) print s "\t" m[s] "\t" ch[s] > stats }' "$MAP" - \
    | bgzip -c > "$part.tmp" && mv "$part.tmp" "$part" && echo "  done $2"
}
export -f one_contig
log "start rewrite: $IN"
tabix -H "$IN" | sed '2a ##SpliceAI_symbols=rewritten to Ensembl 110 gene names (VEP 110 cache), linked via HGNC prev_symbol/alias_symbol from hgnc_complete_set.txt' | bgzip -c > "$TMP/00000.vcf.gz"
tabix -l "$IN" | awk '{printf "%05d\t%s\n", NR, $1}' | xargs -P "$JOBS" -L 1 bash -c 'one_contig "$0" "$1"'
n_want=$(( $(tabix -l "$IN" | wc -l) + 1 )); n_have=$(ls "$TMP"/*.vcf.gz | wc -l)
[ "$n_have" -eq "$n_want" ] || { log "!! only $n_have of $n_want pieces, rerun to resume"; exit 1; }
cat "$TMP"/*.stats 2>/dev/null | awk -F'\t' '{n[$1"\t"$2]+=$3} END {for (k in n) print k "\t" n[k]}' | sort -k3,3nr > "$REF/hgnc/spliceai_symbol_changes.tsv"
log "renamed: $(wc -l < "$REF/hgnc/spliceai_symbol_changes.tsv") symbols, $(awk '{s+=$3} END {print s}' "$REF/hgnc/spliceai_symbol_changes.tsv") records"
log "concatenating"; cat $(ls "$TMP"/*.vcf.gz | sort) > "$OUT.tmp" && mv "$OUT.tmp" "$OUT"
log "indexing"; tabix -f -p vcf "$OUT"
log "check: contigs $(tabix -l "$OUT" | wc -l)"
rm -rf "$TMP"; log "DONE $OUT ($(du -h "$OUT" | cut -f1))"
