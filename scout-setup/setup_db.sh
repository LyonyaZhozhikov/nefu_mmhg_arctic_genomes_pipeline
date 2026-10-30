#!/usr/bin/env bash
# setup_db.sh: step 2 inside the "scout" distro. Fills the Scout database with genes, transcripts,
# HPO, Orphanet and the lab's licensed OMIM files (they stay on this PC), and builds the
# OMIM-AUTO gene panel. Run as root after install_inside.sh and a distro restart:
#   wsl -d scout -u root bash /mnt/c/NGS_pipeline/Claude_folder/scout-setup/setup_db.sh
# Re-running it wipes the Scout database (cases included).
set -euo pipefail
KIT=$(cd "$(dirname "$0")" && pwd)
RES=/opt/scout/resources
OMIM=/mnt/c/NGS_interpretation_tool_vtopil/carrier_app/OMIM
INSTITUTE=${INSTITUTE:-nefu_mmhg_arcgen}
ADMIN_MAIL=admin@arcgen.local
export SCOUT_CONFIG=/opt/scout/config.py
SC="scout --flask-config $SCOUT_CONFIG"

say() { printf '\e[1;36m>>\e[0m %s\n' "$*"; }
die() { printf '\e[1;31mОШИБКА:\e[0m %s\n' "$*" >&2; exit 1; }
[ "$(id -u)" = 0 ] || die "запустите от root"
systemctl is-active -q mongod || die "MongoDB не запущена: systemctl status mongod (дистрибутив перезапускали после install_inside.sh?)"

mkdir -p "$RES"
say "общедоступные справочники из комплекта (HGNC, gnomAD constraint, HPO)"
[ "$(cat "$KIT"/resources/scout_public_resources.tar.gz.part* | md5sum | cut -d' ' -f1)" = "$(cat "$KIT"/resources/scout_public_resources.tar.gz.md5)" ] \
  || die "архив справочников повреждён"
cat "$KIT"/resources/scout_public_resources.tar.gz.part* | tar xzf - -C "$RES"

say "OMIM из лицензионных файлов лаборатории"
cp "$OMIM/genemap2.txt" "$RES/genemap2.txt"
cp "$OMIM/mim2gene.txt" "$RES/mim2genes.txt"

say "Ensembl (гены и транскрипты GRCh37/38) и Orphanet: качаю по одному, с повторами при обрыве"
# Each download goes to a temp folder and is moved in only when it finished without error,
# so a broken connection never leaves a half-written file behind.
fetch() {   # fetch NAME "scout download ..." FILE...
  local name=$1 cmd=$2; shift 2
  local f ok=1
  for f in "$@"; do [ -s "$RES/$f" ] || ok=0; done
  [ $ok = 1 ] && { say "$name: уже скачано"; return 0; }
  local try tmp=$RES/.tmp_download
  for try in 1 2 3 4 5 6; do
    rm -rf "$tmp"; mkdir -p "$tmp"
    say "$name: попытка $try"
    if $SC $cmd --out-dir "$tmp"; then
      ok=1
      for f in "$@"; do [ -s "$tmp/$f" ] || ok=0; done
      if [ $ok = 1 ]; then
        for f in "$@"; do mv -f "$tmp/$f" "$RES/$f"; done
        rm -rf "$tmp"; return 0
      fi
    fi
    sleep $((try * 30))
  done
  die "$name не скачалось за 6 попыток (schug.scilifelab.se / orphadata.com). Попробуйте с VPN или без него и запустите setup_db.sh снова: скачанное сохранится"
}
# Ensembl straight from BioMart, chromosome by chromosome (schug.scilifelab.se kept dropping)
/opt/scout/venv/bin/python "$KIT/scripts/biomart_fetch.py" "$RES" --build 38 37 || die "Ensembl не скачался: переключите VPN и запустите setup_db.sh снова, скачанные хромосомы сохранятся"
fetch "Orphanet" "download orpha" orphadata_en_product4.xml orphadata_en_product6.xml en_product9_ages.xml

say "создаю базу (институт $INSTITUTE, пользователь $ADMIN_MAIL)"
$SC setup -i "$INSTITUTE" -e "$ADMIN_MAIL" -n Admin database --files "$RES" --yes
# 'setup database' ignores local OMIM files (scout 4.115: genemap_path vs genemap2_path),
# so genes and diseases are reloaded from the folder, which does read them.
$SC update genes -f "$RES"
$SC update diseases -f "$RES"
$SC update omim --institute "$INSTITUTE" --genemap2 "$RES/genemap2.txt" --mim2genes "$RES/mim2genes.txt"
$SC update institute "$INSTITUTE" --display-name "NGS lab" 2>/dev/null || true

systemctl restart scout-web
sleep 5
curl -s -o /dev/null -w '%{http_code}' http://127.0.0.1:8000/ | grep -q 200 && say "Scout работает: http://localhost:8000 , вход по адресу $ADMIN_MAIL" \
  || die "веб-сервер не отвечает: journalctl -u scout-web -n 50"
