# export_old_pc.ps1: snapshot of the whole pipeline onto the dock disk (E:), run on the OLD PC
# only after the queue has finished. Copies WSL Ubuntu-24.04 (pipeline, references, docker images),
# WSL scout, C:\NGS_pipeline (without samples), .wslconfig and keep-alive scripts.
param([string]$Dest = "E:\pc_clone")
$ErrorActionPreference = "Stop"
$Startup = [Environment]::GetFolderPath("Startup")

Write-Host "== Проверка, что ничего не считается ==" -ForegroundColor Cyan
$tm = (wsl.exe -d Ubuntu-24.04 -u ngs -- bash -c "tmux ls 2>/dev/null | cut -d: -f1") -join " "
if ($tm -match "run_|ngs_queue") { throw "Идёт прогон/очередь ($tm). Дождитесь окончания (ngs status)." }
wsl.exe -d Ubuntu-24.04 -u ngs -- bash -c "echo; df -h /data | tail -1; du -sh /data/raredisease/references /data/raredisease/samples /data/raredisease/runs 2>/dev/null; echo; ls /data/raredisease/runs"
Write-Host ""
Write-Host "Выше: что уйдёт в копию. Если в runs\ остались прогоны, которые не нужны, удалите их ДО копии (ngs discard)."
$ok = Read-Host "Продолжить? Компьютер не трогать 3-5 часов (YES)"
if ($ok -ne "YES") { exit 1 }

New-Item -ItemType Directory -Force -Path $Dest | Out-Null
Write-Host "== Останавливаю WSL ==" -ForegroundColor Cyan
wsl.exe --shutdown
Start-Sleep 10

$t0 = Get-Date
Write-Host "== Экспорт Ubuntu-24.04 -> $Dest\ubuntu_ngs.tar (долго) ==" -ForegroundColor Cyan
wsl.exe --export Ubuntu-24.04 "$Dest\ubuntu_ngs.tar"
if ($LASTEXITCODE -ne 0) { throw "экспорт Ubuntu-24.04 не удался" }
$distros = (wsl.exe -l -q) -replace "`0", "" | Where-Object { $_ -ne "" }
if ($distros -contains "scout") {
    Write-Host "== Экспорт scout -> $Dest\scout.tar ==" -ForegroundColor Cyan
    wsl.exe --export scout "$Dest\scout.tar"
    if ($LASTEXITCODE -ne 0) { throw "экспорт scout не удался" }
}

Write-Host "== Копирую C:\NGS_pipeline (без образцов) и настройки ==" -ForegroundColor Cyan
robocopy C:\NGS_pipeline "$Dest\NGS_pipeline" /E /XD new_samples new_results results_SAMPLE03 /NFL /NDL /NP | Out-Null
Copy-Item "$env:USERPROFILE\.wslconfig" "$Dest\wslconfig.txt" -ErrorAction SilentlyContinue
New-Item -ItemType Directory -Force -Path "$Dest\startup" | Out-Null
Get-ChildItem $Startup -Filter *keepalive*.vbs | Copy-Item -Destination "$Dest\startup"
Copy-Item "$PSScriptRoot\import_new_pc.ps1", "$PSScriptRoot\IMPORT_NEW_PC.bat" $Dest -ErrorAction SilentlyContinue

Get-ChildItem $Dest -File | Select-Object Name, @{n="GB";e={[math]::Round($_.Length/1GB,1)}} | Format-Table | Out-String | Tee-Object "$Dest\sizes.txt"
Write-Host ("Готово за {0:hh\:mm}. Копия в $Dest" -f ((Get-Date) - $t0)) -ForegroundColor Green

Write-Host "== Запускаю WSL обратно (keep-alive) ==" -ForegroundColor Cyan
Get-ChildItem $Startup -Filter *keepalive*.vbs | ForEach-Object { Start-Process wscript.exe $_.FullName }
