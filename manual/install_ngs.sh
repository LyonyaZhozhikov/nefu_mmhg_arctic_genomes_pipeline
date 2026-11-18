#!/usr/bin/env bash
# One-time setup of the "ngs" command on the lab PC. Run in the Ubuntu window:
#   bash /mnt/c/NGS_pipeline/Claude_folder/manual/install_ngs.sh
set -euo pipefail
HERE=$(cd "$(dirname "$0")" && pwd)
SETUP=/home/ngs/raredisease-setup
GOOD_PARAMS=/data/raredisease/runs/SAMPLE01/params.yaml   # params of the checked full setup

for t in rsync tmux nextflow docker; do command -v $t >/dev/null || { echo "нет программы $t"; exit 1; }; done

# new file + rename: a queue or run already executing the old ngs.sh keeps reading the old copy
install -m 755 "$HERE/ngs.sh" "$SETUP/scripts/ngs.sh.new" && mv -f "$SETUP/scripts/ngs.sh.new" "$SETUP/scripts/ngs.sh"
echo "ngs.sh -> $SETUP/scripts/ngs.sh"

if [ ! -f "$SETUP/params_template.yaml" ]; then
  grep -q vep_files_spliceai_cadd "$GOOD_PARAMS" || { echo "в $GOOD_PARAMS нет полной настройки VEP, шаблон не создан"; exit 1; }
  cp "$GOOD_PARAMS" "$SETUP/params_template.yaml"
  echo "шаблон параметров: $SETUP/params_template.yaml (копия $GOOD_PARAMS)"
fi

# intake (автоприём из Очереди): settings once, autostart with Windows
[ -f "$SETUP/conf/intake.conf" ] || { install -m 644 "$HERE/intake.conf" "$SETUP/conf/intake.conf"; echo "настройки автоприёма: $SETUP/conf/intake.conf"; }
if mountpoint -q /mnt/d && [ -d /mnt/d/data_annotated ]; then
  mkdir -p /mnt/d/data_annotated/Очередь /mnt/d/1_fastq_rec /mnt/d/2_fastq || true
fi
VBS=$HERE/ngs_intake_autostart.vbs; [ -f "$VBS" ] || VBS=$HERE/../windows/startup/ngs_intake_autostart.vbs
if [ -f "$VBS" ] && command -v cmd.exe >/dev/null; then
  APPD=$(cd /mnt/c && cmd.exe /c 'echo %APPDATA%' 2>/dev/null | tr -d '\r' || true)
  STARTUP="$(wslpath -u "$APPD" 2>/dev/null || true)/Microsoft/Windows/Start Menu/Programs/Startup"
  if [ -d "$STARTUP" ] && sed 's/$/\r/' "$VBS" > "$STARTUP/ngs_intake_autostart.vbs"; then
    echo "автозапуск автоприёма: $STARTUP/ngs_intake_autostart.vbs"
  else
    echo "!! не смог положить автозапуск в Startup: скопируйте ngs_intake_autostart.vbs туда вручную (Win+R, shell:startup)"
  fi
fi

grep -q "alias ngs=" ~/.bashrc || echo "alias ngs='bash $SETUP/scripts/ngs.sh'" >> ~/.bashrc
mkdir -p /mnt/c/NGS_pipeline/new_samples /mnt/c/NGS_pipeline/new_results
sed 's/$/\r/' "$HERE/NGS.bat" > /mnt/c/NGS_pipeline/NGS.bat
echo "ярлык: C:\\NGS_pipeline\\NGS.bat"
echo "Готово. Закройте и снова откройте окно Ubuntu, затем наберите: ngs"
echo "Автоприём из Очереди: ngs intake sex (пол), ngs intake start (включить сейчас; дальше включается сам с Windows)"
