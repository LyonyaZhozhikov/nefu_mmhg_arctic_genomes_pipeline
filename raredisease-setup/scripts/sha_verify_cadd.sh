#!/usr/bin/env bash
# Re-verify the CADD annotation tarball copy on D: against the source sha256 recorded in ~/mvcadd.log.
# Reads with dd in 16 MB blocks (plain sha256sum on drvfs failed with "Cannot allocate memory").
set -uo pipefail
DST=${DST:-/mnt/d/reference_archive/cadd/GRCh38_v1.7.tar.gz}
LOG=~/mvcadd.log
src=$(grep -o 'sha256 src=[0-9a-f]*' "$LOG" | tail -1 | cut -d= -f2)
echo "=== sha256 re-verify (dd) $(date -Iseconds) dst=$DST" >> "$LOG"
dst=$(dd if="$DST" bs=16M status=none | sha256sum | cut -d' ' -f1)
echo "sha256 src=$src dst=$dst" >> "$LOG"
if [ -n "$dst" ] && [ "$src" = "$dst" ]; then echo "VERIFIED OK $(date -Iseconds)" >> "$LOG"; else echo "MISMATCH (re-verify) $(date -Iseconds)" >> "$LOG"; fi
tail -3 "$LOG"
