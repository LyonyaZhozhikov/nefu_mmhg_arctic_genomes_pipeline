#!/usr/bin/env bash
# Waits for the T7 Shield drive to come back with gnomAD tmp_chrN.vcf.bgz files from the second PC,
# imports them (rsync --append resumes partial ones), releases the drive, then downloads the rest of chr13-Y.
# Usage: bash t7_watch.sh [REF]     (run in tmux; log ~/t7_watch.log)
REF=${1:-/data/raredisease/references/grch38}; S=$(cd "$(dirname "$0")" && pwd)
CHRS="13 14 15 16 17 18 19 20 21 22 X Y"
log() { echo "$(date '+%F %T') $*"; }
t7() { powershell.exe -NoProfile -Command "(Get-Volume -FileSystemLabel 'T7 Shield' -ErrorAction SilentlyContinue).DriveLetter" 2>/dev/null | tr -d '\r\n '; }
# The drive is still plugged in now: first wait for it to be ejected, so we never hold it while the user ejects
log "waiting for T7 Shield to be ejected"; while [ -n "$(t7)" ]; do sleep 30; done
log "waiting for T7 Shield to come back"
while :; do
  L=$(t7)
  if [ -n "$L" ]; then
    M=/mnt/${L,,}; sudo mkdir -p "$M"; mountpoint -q "$M" || sudo mount -t drvfs "$L:" "$M" -o uid=$(id -u),gid=$(id -g) 2>/dev/null
    D=$(find "$M" -maxdepth 4 -regextype egrep -regex '.*/tmp_chr(1[3-9]|2[0-2]|X|Y)\.vcf\.bgz' 2>/dev/null | head -1)
    if [ -n "$D" ]; then
      D=$(dirname "$D"); log "found files in $D, waiting until the copy onto the drive stops"
      a=; b=x; while [ "$a" != "$b" ]; do a=$(du -sb "$D" | cut -f1); sleep 120; b=$(du -sb "$D" | cut -f1); done
      for c in $CHRS; do f=$D/tmp_chr$c.vcf.bgz; [ -e "$f" ] || continue
        log "import chr$c ($(( $(stat -c %s "$f")/1000000000 )) GB)"; rsync -a --append "$f" "$REF/vcfanno/"; done
      cd /; sync; sudo umount "$M" && log "T7 RELEASED: safe to eject"
      break
    fi
    mountpoint -q "$M" && sudo umount "$M"   # no files yet: don't hold the drive
  fi
  sleep 60
done
log "gnomAD chr13-Y: resume/verify"
for i in 1 2 3; do CHR="$CHRS" bash "$S/fetch_hub.sh" "$REF" gnomad 3 && break; done
bash "$S/fetch_hub.sh" "$REF" status > ~/hub_status.txt; log "gnomAD chr13-Y finished"
