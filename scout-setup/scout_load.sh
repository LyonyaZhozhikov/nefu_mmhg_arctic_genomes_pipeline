#!/usr/bin/env bash
# scout_load.sh: put an archived raredisease run into Scout (run inside the "scout" distro).
#
#   scout_load.sh RUN               load or reload a case; RUN = folder in D:\data_annotated
#                                   (e.g. 2026-10-22_SAMPLE03_M) or a full path
#   scout_load.sh research RUN      also load the full research SNV/SV set (asked for in Scout
#                                   with "Request research"; takes longer)
#   scout_load.sh list              cases in Scout
#
# Nothing is copied: Scout reads VCF/BAM straight from D:. The load config is kept in
# /opt/scout/cases/<RUN>.yaml.
set -euo pipefail
KIT=$(cd "$(dirname "$0")" && pwd)
ARCHIVE=${ARCHIVE:-/mnt/d/data_annotated}
INSTITUTE=${INSTITUTE:-nefu_mmhg_arcgen}
CASES=${CASES:-/opt/scout/cases}
export SCOUT_CONFIG=${SCOUT_CONFIG:-/opt/scout/config.py}
SC="${SCOUT_BIN:-scout} --flask-config $SCOUT_CONFIG"
PY=${PY:-/opt/scout/venv/bin/python}

say() { printf '\e[1;36m>>\e[0m %s\n' "$*"; }
die() { printf '\e[1;31mОШИБКА:\e[0m %s\n' "$*" >&2; exit 1; }

# Scout 4.115.2 crashes on VEP SpliceAI entries where only some of the four delta scores are
# filled (max() of None and float); our SpliceAI file built from CADD has such rows.
patch_scout() {
  local f; f=$($PY -c "import scout.parse.variant.transcript as t; print(t.__file__)")
  grep -q 'max(spliceai_delta_scores)' "$f" || return 0
  sed -i 's/spliceai_delta_score = max(spliceai_delta_scores)/spliceai_delta_score = max(s for s in spliceai_delta_scores if s is not None)/' "$f"
  say "исправлена ошибка Scout с пустыми значениями SpliceAI"
  systemctl restart scout-web 2>/dev/null || true
}

run_dir() {
  local r=${1%/}; r=${r%\\}
  if [[ $r =~ ^([A-Za-z]):[\\/](.*)$ ]]; then
    r="/mnt/${BASH_REMATCH[1],,}/${BASH_REMATCH[2]//\\//}"
  elif [[ $r != /* ]]; then
    r=$ARCHIVE/$r
  fi
  [ -d "$r/processed" ] || die "нет папки processed в $r"
  echo "$r"
}

load_case() {
  local run; run=$(run_dir "$1")
  local name; name=$(basename "$run")
  mkdir -p "$CASES"
  local yaml=$CASES/$name.yaml
  $PY "$KIT/scripts/make_scout_config.py" "$run" -o "$yaml" --institute "$INSTITUTE"
  local fam; fam=$($PY -c "import yaml,sys; print(yaml.safe_load(open(sys.argv[1]))['family'])" "$yaml")
  if $SC view cases -i "$INSTITUTE" 2>/dev/null | grep -qw "$fam"; then
    say "кейс $fam уже есть: обновляю (решения и комментарии сохраняются)"
    $SC load case --update --keep-actions "$yaml"
  else
    say "загружаю кейс $fam"
    $SC load case "$yaml"
  fi
  say "готово: http://localhost:8000/$INSTITUTE/$fam"
}

load_research() {
  local run; run=$(run_dir "$1")
  local name; name=$(basename "$run")
  [ -f "$CASES/$name.yaml" ] || load_case "$1"
  local fam; fam=$($PY -c "import yaml,sys; print(yaml.safe_load(open(sys.argv[1]))['family'])" "$CASES/$name.yaml")
  say "загружаю research-набор для $fam (может занять 10-30 минут)"
  $SC load research -c "$fam" -i "$INSTITUTE" --force
}

patch_scout

case "${1:-}" in
  list) $SC view cases -i "$INSTITUTE" ;;
  research) [ -n "${2:-}" ] || die "укажите прогон"; load_research "$2" ;;
  ""|-h|--help) sed -n 2,12p "$0" ;;
  *) load_case "$1" ;;
esac
