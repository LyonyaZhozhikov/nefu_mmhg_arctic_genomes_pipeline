#!/usr/bin/env bash
# PC2, step 2 (as ngs): unpack the kit from F:\pc2_kit and install the ngs command.
#   wsl -d Ubuntu-24.04 -u ngs -- bash /mnt/f/pc2_kit/kit_import.sh
set -uo pipefail
KIT=$(cd "$(dirname "$0")" && pwd)   # the kit folder this script is run from (T7 may get another letter here)
REFS=/data/raredisease/references
[ -d "$KIT" ] || { echo "нет $KIT"; exit 1; }
log() { echo "$(TZ=Asia/Yakutsk date '+%F %T') $*" | tee -a ~/kit_import.log; }
fail=0

mkdir -p "$REFS/grch38"
for t in "$KIT"/refs_*.tar; do
  [ -f "$t.ok" ] || { log "$(basename "$t"): нет отметки готовности, пропускаю"; fail=1; continue; }
  case "$(basename "$t")" in refs_top_*) dest=$REFS ;; *) dest=$REFS/grch38 ;; esac
  log "распаковываю $(basename "$t")"
  tar -xf "$t" -C "$dest" || { log "ОШИБКА в $(basename "$t")"; fail=1; }
done

log "загружаю Docker-образы"
docker load -i "$KIT/docker_images.tar" >/dev/null || { log "ОШИБКА docker load"; fail=1; }
log "кэш Nextflow"; tar -xf "$KIT/nextflow_home.tar" -C "$HOME" || fail=1

log "папка настроек"
rm -f ~/raredisease-setup 2>/dev/null   # a symlink, if any
tar -xf "$KIT/raredisease_setup.tar" -C "$HOME" || fail=1
[ -d ~/raredisease-setup ] || mv ~/"$(tar -tf "$KIT/raredisease_setup.tar" | head -1 | cut -d/ -f1)" ~/raredisease-setup

# the ngs command (also creates C:\NGS_pipeline\NGS.bat and new_samples)
mkdir -p /mnt/c/NGS_pipeline
bash "$KIT/manual/install_ngs.sh" || fail=1
mkdir -p /mnt/c/NGS_pipeline/Claude_folder && cp -r "$KIT/manual" /mnt/c/NGS_pipeline/Claude_folder/

log "проверка: $(docker images | tail -n +2 | wc -l) образов, references $(du -sh $REFS | cut -f1)"
bash ~/raredisease-setup/scripts/ngs.sh check || fail=1
[ $fail = 0 ] && log "ГОТОВО" || log "есть ошибки, см. выше"
