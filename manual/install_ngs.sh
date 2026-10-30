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

grep -q "alias ngs=" ~/.bashrc || echo "alias ngs='bash $SETUP/scripts/ngs.sh'" >> ~/.bashrc
mkdir -p /mnt/c/NGS_pipeline/new_samples /mnt/c/NGS_pipeline/new_results
sed 's/$/\r/' "$HERE/NGS.bat" > /mnt/c/NGS_pipeline/NGS.bat
echo "ярлык: C:\\NGS_pipeline\\NGS.bat"
echo "Готово. Закройте и снова откройте окно Ubuntu, затем наберите: ngs"
