#!/usr/bin/env bash
# Moves ~/raredisease-setup from the Windows disk (symlink to /mnt/c/NGS_pipeline/raredisease-setup)
# into the Ubuntu ext4 disk. Scripts read over the WSL->Windows bridge sometimes fail with
# "Input/output error", which broke a queue auto-resume. Run only when nothing is computing:
#   bash /mnt/c/NGS_pipeline/Claude_folder/second_pc/move_setup_into_wsl.sh
set -euo pipefail
LINK=/home/ngs/raredisease-setup
SRC=/mnt/c/NGS_pipeline/raredisease-setup

if tmux ls 2>/dev/null | grep -qE '^(run_|ngs_queue)'; then
  echo "идёт прогон или очередь (ngs status). Запустите, когда всё закончится."; exit 1
fi
if [ ! -L "$LINK" ]; then
  echo "$LINK уже обычная папка внутри Ubuntu, делать нечего."; exit 0
fi
[ "$(readlink -f "$LINK")" = "$SRC" ] || { echo "ссылка указывает не туда: $(readlink -f "$LINK")"; exit 1; }

echo "копирую $SRC -> $LINK.new"
rsync -a "$SRC"/ "$LINK.new"/
diff -rq "$SRC" "$LINK.new" && echo "копия совпадает"
sudo rm "$LINK"                      # removes only the symlink, not the Windows folder
mv "$LINK.new" "$LINK"
chmod +x "$LINK"/scripts/*.sh 2>/dev/null || true
echo "Готово: $LINK теперь внутри Ubuntu."
echo "Папка C:\\NGS_pipeline\\raredisease-setup осталась как резервная копия, Ubuntu её больше не использует."
ls -ld "$LINK"
