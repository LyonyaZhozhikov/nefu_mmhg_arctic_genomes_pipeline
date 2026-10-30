# import_new_pc.ps1: restore the pipeline on the NEW PC from the dock disk copy.
# Run from the copy folder (E:\pc_clone) in PowerShell as Administrator. WSL must be installed
# (wsl --install --no-distribution, then reboot).
param([string]$Src = $PSScriptRoot,
      [string]$UbuntuDir = "C:\WSL\Ubuntu-24.04",
      [string]$ScoutDir = "D:\scout\wsl")
$ErrorActionPreference = "Stop"
$Startup = [Environment]::GetFolderPath("Startup")
$distros = (wsl.exe -l -q) -replace "`0", "" | Where-Object { $_ -ne "" }

if ($distros -contains "Ubuntu-24.04") { throw "Ubuntu-24.04 уже есть на этом ПК. Удалите её (wsl --unregister Ubuntu-24.04) или спросите Claude." }

Write-Host "== .wslconfig ==" -ForegroundColor Cyan
if (Test-Path "$Src\wslconfig.txt") { Copy-Item "$Src\wslconfig.txt" "$env:USERPROFILE\.wslconfig" -Force }

Write-Host "== Импорт Ubuntu-24.04 в $UbuntuDir (долго) ==" -ForegroundColor Cyan
New-Item -ItemType Directory -Force -Path $UbuntuDir | Out-Null
wsl.exe --import Ubuntu-24.04 $UbuntuDir "$Src\ubuntu_ngs.tar" --version 2
if ($LASTEXITCODE -ne 0) { throw "импорт Ubuntu-24.04 не удался" }
# imported distros start as root; make ngs the default user again
wsl.exe -d Ubuntu-24.04 -u root -- bash -c "grep -q '^default=ngs' /etc/wsl.conf 2>/dev/null || printf '\n[user]\ndefault=ngs\n' >> /etc/wsl.conf"
wsl.exe --manage Ubuntu-24.04 --set-default-user ngs 2>$null
wsl.exe --set-default Ubuntu-24.04

if ((Test-Path "$Src\scout.tar") -and ($distros -notcontains "scout")) {
    Write-Host "== Импорт scout в $ScoutDir ==" -ForegroundColor Cyan
    New-Item -ItemType Directory -Force -Path $ScoutDir | Out-Null
    wsl.exe --import scout $ScoutDir "$Src\scout.tar" --version 2
    if ($LASTEXITCODE -ne 0) { throw "импорт scout не удался" }
}

Write-Host "== C:\NGS_pipeline и автозапуск ==" -ForegroundColor Cyan
robocopy "$Src\NGS_pipeline" C:\NGS_pipeline /E /NFL /NDL /NP | Out-Null
New-Item -ItemType Directory -Force -Path C:\NGS_pipeline\new_samples | Out-Null
Get-ChildItem "$Src\startup" -Filter *.vbs | Copy-Item -Destination $Startup -Force

wsl.exe --shutdown
Start-Sleep 8
Get-ChildItem $Startup -Filter *keepalive*.vbs | ForEach-Object { Start-Process wscript.exe $_.FullName }
Start-Sleep 15

Write-Host "== Проверка ==" -ForegroundColor Cyan
wsl.exe -d Ubuntu-24.04 -u ngs -- bash -lc "whoami; docker images | wc -l; df -h /data | tail -1; bash ~/raredisease-setup/scripts/ngs.sh check"
Write-Host "Готово. Откройте C:\NGS_pipeline\NGS.bat. Если что-то красное выше, пришлите скрин Claude." -ForegroundColor Green
