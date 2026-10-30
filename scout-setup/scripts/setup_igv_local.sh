#!/usr/bin/env bash
# setup_igv_local.sh: make IGV in Scout work without outside servers (run as root in the "scout" distro):
#   wsl -d scout -u root bash /mnt/c/NGS_pipeline/Claude_folder/scout-setup/scripts/setup_igv_local.sh
# Downloads the hg38 reference (~3.3 GB) and the annotation tracks once into /opt/scout/igv/hg38
# (inside the scout disk on D:), points Scout at them and switches users to these local tracks.
# Safe to re-run: finished files are skipped, broken downloads resume.
set -euo pipefail
DIR=/opt/scout/igv/hg38
CONF=/opt/scout/config.py
say() { printf '\e[1;36m>>\e[0m %s\n' "$*"; }
warn() { printf '\e[1;33m!!\e[0m %s\n' "$*"; }
die() { printf '\e[1;31mОШИБКА:\e[0m %s\n' "$*" >&2; exit 1; }
[ "$(id -u)" = 0 ] || die "запустите от root"
mkdir -p "$DIR"

get() {   # get "URL [MIRROR...]" FILE [optional]
  local urls=$1 out=$DIR/$2 opt=${3:-}
  [ -s "$out" ] && { say "$2: уже есть"; return 0; }
  say "$2: качаю"
  local t url
  for t in 1 2 3 4 5 6; do
    for url in $urls; do
      if curl -fL --retry 3 --connect-timeout 30 -C - -o "$out.part" "$url"; then
        mv -f "$out.part" "$out"; return 0
      fi
      warn "$2: не отдал ${url#https://}"
    done
    [ $t -lt 6 ] && { warn "$2: повтор $t/6"; sleep $((t * 20)); }
  done
  [ -n "$opt" ] && { warn "$2 не скачался, дорожка будет пропущена"; rm -f "$out.part"; return 0; }
  die "$2 не скачался. Запустите скрипт ещё раз (с VPN или без), скачанное продолжится"
}

get https://s3.amazonaws.com/igv.broadinstitute.org/genomes/seq/hg38/hg38.fa.fai hg38.fa.fai
get https://s3.amazonaws.com/igv.broadinstitute.org/genomes/seq/hg38/hg38.fa hg38.fa
get "https://hgdownload.soe.ucsc.edu/goldenPath/hg38/database/cytoBandIdeo.txt.gz https://igv-genepattern-org.s3.amazonaws.com/genomes/hg38/cytoBandIdeo.txt.gz" cytoBandIdeo.txt.gz
get https://raw.githubusercontent.com/igvteam/igv-data/refs/heads/main/data/hg38/hg38_alias.tab hg38_alias.tab
get https://hgdownload.soe.ucsc.edu/goldenPath/hg38/database/ncbiRefSeq.txt.gz ncbiRefSeq.txt.gz
get https://ftp.ncbi.nlm.nih.gov/refseq/MANE/trackhub/data/release_1.5/MANE.GRCh38.v1.5.ensembl.bb MANE.GRCh38.v1.5.ensembl.bb opt
get https://hgdownload.soe.ucsc.edu/gbdb/hg38/bbi/clinvar/clinvarMain.bb clinvarMain.bb opt
get https://ftp.ncbi.nlm.nih.gov/pub/dbVar/sandbox/dbvarhub/hg38/clinvar_pathogenic.bb clinvar_pathogenic.bb opt
get https://hgdownload.soe.ucsc.edu/gbdb/hg38/nmd/nmdEscMane.bb nmdEscMane.bb opt

# Scout serves local files with the URL /remote/static?file=..., so igv.js cannot tell a .gz
# from the name: keep the text tracks uncompressed.
[ -s "$DIR/cytoBandIdeo.txt" ] || gunzip -c "$DIR/cytoBandIdeo.txt.gz" > "$DIR/cytoBandIdeo.txt"
[ -s "$DIR/ncbiRefSeq.txt" ] || gunzip -c "$DIR/ncbiRefSeq.txt.gz" > "$DIR/ncbiRefSeq.txt"
# a truncated fasta would show wrong bases: compare its size with the end of the last fai record
want=$(tail -n 1 "$DIR/hg38.fa.fai" | awk -F'\t' '{ r = $2 % $4; print $3 + int($2 / $4) * $5 + (r ? r + $5 - $4 : 0) }')
have=$(stat -c %s "$DIR/hg38.fa")
[ "$have" -ge "$want" ] || die "hg38.fa неполный ($have из $want байт): удалите $DIR/hg38.fa и запустите снова"

say "настраиваю Scout на локальные дорожки"
/opt/scout/venv/bin/python - "$DIR" "$CONF" <<'EOF'
import os, re, sys
d, conf = sys.argv[1], sys.argv[2]
tracks = [
    ("Genes RefSeq", "annotation", "refgene", "ncbiRefSeq.txt"),
    ("MANE v1.5", "annotation", "bigBed", "MANE.GRCh38.v1.5.ensembl.bb"),
    ("ClinVar SNV", "annotation", "bigBed", "clinvarMain.bb"),
    ("ClinVar SV", "annotation", "bigBed", "clinvar_pathogenic.bb"),
    ("NMD escape", "annotation", "bigBed", "nmdEscMane.bb"),
]
tracks = [dict(name=n, type=t, format=f, url=os.path.join(d, p), build="38")
          for n, t, f, p in tracks if os.path.exists(os.path.join(d, p))]
block = (
    "# --- local IGV tracks (setup_igv_local.sh) ---\n"
    "CUSTOM_REFERENCE = %r\n"
    "CUSTOM_IGV_TRACKS = %r\n"
    "# --- end local IGV tracks ---\n"
) % (
    {"38": dict(name="Human GRCh38/hg38",
                fastaURL=d + "/hg38.fa", indexURL=d + "/hg38.fa.fai",
                cytobandURL=d + "/cytoBandIdeo.txt", aliasURL=d + "/hg38_alias.tab",
                chromosomeOrder=", ".join(["chr%s" % c for c in list(range(1, 23)) + ["X", "Y", "M"]]))},
    [{"name": "Local hg38 tracks", "tracks": tracks}],
)
text = open(conf).read()
text = re.sub(r"# --- local IGV tracks.*?# --- end local IGV tracks ---\n", "", text, flags=re.S)
open(conf, "w").write(text.rstrip("\n") + "\n\n" + block)
open(os.path.join(d, "track_names.txt"), "w").write("\n".join(t["name"] for t in tracks))
print("   дорожки: " + ", ".join(t["name"] for t in tracks))
EOF

# The built-in tracks (Genes, MANE Transcripts, ClinVar...) always point to outside servers;
# a user's IGV list decides which tracks load, so it gets only the local ones.
names=$(python3 -c "import json,sys; print(json.dumps(open(sys.argv[1]).read().split('\n')))" "$DIR/track_names.txt")
mongosh --quiet scout --eval "print('пользователей: ' + db.user.updateMany({}, {\$set: {igv_tracks: $names}}).modifiedCount)"

systemctl restart scout-web
sleep 5
curl -s -o /dev/null -w '%{http_code}' http://127.0.0.1:8000/ | grep -q 200 \
  && say "готово: откройте IGV в Scout заново (Ctrl+F5)" \
  || die "Scout не поднялся: journalctl -u scout-web -n 50"
