#!/usr/bin/env bash
# PC1 (Ubuntu): put everything slow to download onto the dock disk, without stopping the queue.
#   bash /mnt/c/NGS_pipeline/Claude_folder/second_pc/kit_export.sh
# Writes F:\pc2_kit\: refs_<dir>.tar per reference folder (hardlinks kept), docker_images.tar,
# nextflow_home.tar (pipeline code + plugins), raredisease_setup.tar, wslconfig.txt, keepalive vbs.
# References are only read, so a running queue is not disturbed (no idle I/O class: it ran at ~6 MB/s); each write waits for a low-RAM
# phase of the running sample (writes to /mnt/f fail with "Cannot allocate memory" otherwise).
set -uo pipefail
REFS=/data/raredisease/references
OUT=/mnt/f/pc2_kit
log() { echo "$(TZ=Asia/Yakutsk date '+%F %T') $*" | tee -a "$OUT/kit_export.log"; }

mountpoint -q /mnt/f || { sudo -n mkdir -p /mnt/f && sudo -n mount -t drvfs F: /mnt/f; } || { echo "диск F: (T7) не подключён к Ubuntu: sudo mkdir -p /mnt/f && sudo mount -t drvfs F: /mnt/f"; exit 1; }
mkdir -p "$OUT"

wait_ram() {   # up to 2 h for >= 24 GB available, then free the page cache
  local w=0
  while [ "$(awk '/MemAvailable/{print int($2/1048576)}' /proc/meminfo)" -lt 24 ] && [ $w -lt 120 ]; do sleep 60; w=$((w+1)); done
  sync; echo 3 | sudo -n tee /proc/sys/vm/drop_caches >/dev/null 2>&1 || true
}
# tar SRC_PARENT NAME -> $OUT/NAME.tar, retried; a finished part is skipped on rerun (.ok marker)
pack() {
  local parent=$1 name=$2 tarname=$3 try
  [ -f "$OUT/$tarname.ok" ] && { log "$tarname: уже готов, пропускаю"; return 0; }
  for try in 1 2 3 4 5 6 7 8 9 10 11 12; do
    wait_ram
    log "$tarname: пишу ($(du -sh "$parent/$name" | cut -f1)), попытка $try"
    # -b 4096: 2 MiB writes; with tar's default 10 KiB records the WSL->Windows bridge managed ~9 MB/s
    if nice -n 10 tar -b 4096 -cf "$OUT/$tarname.tmp" -C "$parent" "$name"; then
      mv -f "$OUT/$tarname.tmp" "$OUT/$tarname" && touch "$OUT/$tarname.ok"
      log "$tarname: готово ($(du -h "$OUT/$tarname" | cut -f1))"; return 0
    fi
    log "$tarname: запись прервалась, повторю через 10 минут"; sleep 600
  done
  log "$tarname: НЕ УДАЛОСЬ"; return 1
}

log "== старт, свободно на F: $(df -h /mnt/f | awk 'NR==2{print $4}') =="
fail=0
# one tar per folder of references/grch38 so a failure repeats only that folder
for d in "$REFS"/grch38/*; do
  pack "$REFS/grch38" "$(basename "$d")" "refs_$(basename "$d").tar" || fail=1
done
for f in "$REFS"/*; do [ "$(basename "$f")" = grch38 ] || pack "$REFS" "$(basename "$f")" "refs_top_$(basename "$f").tar" || fail=1; done

if [ ! -f "$OUT/docker_images.tar.ok" ]; then
  wait_ram
  imgs=$(docker images --format '{{.Repository}}:{{.Tag}}' | grep -v '<none>')
  log "docker: сохраняю $(echo "$imgs" | wc -l) образов"
  if nice -n 19 docker save -o "$OUT/docker_images.tar.tmp" $imgs; then
    mv -f "$OUT/docker_images.tar.tmp" "$OUT/docker_images.tar" && touch "$OUT/docker_images.tar.ok"
    log "docker: готово ($(du -h "$OUT/docker_images.tar" | cut -f1))"
  else log "docker: НЕ УДАЛОСЬ"; fail=1; fi
fi

pack "$HOME" .nextflow nextflow_home.tar || fail=1
pack "$(dirname "$(readlink -f ~/raredisease-setup)")" "$(basename "$(readlink -f ~/raredisease-setup)")" raredisease_setup.tar || fail=1
cp /mnt/c/Users/*/.wslconfig "$OUT/wslconfig.txt" 2>/dev/null || true
cp /mnt/c/NGS_pipeline/Claude_folder/ubuntu_keepalive.vbs /mnt/c/NGS_pipeline/Claude_folder/second_pc/kit_import.sh \
   /mnt/c/NGS_pipeline/Claude_folder/second_pc/setup_ubuntu_pc2.sh "$OUT/" 2>/dev/null || true
mkdir -p "$OUT/manual" && cp /mnt/c/NGS_pipeline/Claude_folder/manual/{ngs.sh,install_ngs.sh,NGS.bat,ngs_guide.html} "$OUT/manual/"
ls -la "$OUT" > "$OUT/contents.txt"
[ $fail = 0 ] && log "== ВСЁ ГОТОВО: $(du -sh "$OUT" | cut -f1) в F:\\pc2_kit ==" || log "== есть ошибки, запустите скрипт ещё раз: готовые части пропустятся =="
