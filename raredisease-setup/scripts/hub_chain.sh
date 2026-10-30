#!/usr/bin/env bash
# Unattended chain for the lab PC (the user can't reach Claude while the VPN is off):
# wait for the T7 import -> gnomAD chr1-12 (fast without VPN) -> CADD (kircherlab, needs VPN: wget retries until it is on).
# Status table is rewritten every 10 min to ~/hub_status.txt.
REF=${1:-/data/raredisease/references/grch38}; H=$(dirname "$0")/fetch_hub.sh
( while sleep 600; do bash "$H" "$REF" status > ~/hub_status.txt.tmp && mv ~/hub_status.txt.tmp ~/hub_status.txt; done ) &
while pgrep -x rsync >/dev/null; do sleep 30; done
echo "$(date) import finished, gnomAD chr1-12"
for i in 1 2 3; do CHR="1 2 3 4 5 6 7 8 9 10 11 12" bash "$H" "$REF" gnomad 3 && break; done
echo "$(date) gnomAD done, CADD (needs VPN)"
bash "$H" "$REF" vpn
bash "$H" "$REF" status > ~/hub_status.txt; echo "$(date) ALL DOWNLOADS FINISHED"
