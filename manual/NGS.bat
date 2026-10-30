@echo off
title NGS pipeline
wsl.exe -d Ubuntu-24.04 -u ngs --cd ~ -- bash -l /home/ngs/raredisease-setup/scripts/ngs.sh menu
pause
