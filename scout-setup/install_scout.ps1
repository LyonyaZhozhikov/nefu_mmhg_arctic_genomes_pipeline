# install_scout.ps1: install Scout in its own WSL distro "scout" whose disk lives on D:\scout\wsl.
# The pipeline distro (Ubuntu on C:) is not touched. Run in a normal PowerShell window:
#   powershell -ExecutionPolicy Bypass -File C:\NGS_pipeline\Claude_folder\scout-setup\install_scout.ps1
# Safe to re-run: finished steps are skipped (setup_db.sh only runs when the database is empty).
$ErrorActionPreference = "Stop"
$Kit = "/mnt/c/NGS_pipeline/Claude_folder/scout-setup"
$Location = "D:\scout\wsl"

function Say($m) { Write-Host ">> $m" -ForegroundColor Cyan }

$distros = (wsl.exe -l -q) -replace "`0", "" | Where-Object { $_ -ne "" }
if ($distros -notcontains "scout") {
    Say "1/4 создаю отдельный Linux 'scout' на D: (скачивание Ubuntu ~350 МБ)"
    New-Item -ItemType Directory -Force -Path $Location | Out-Null
    wsl.exe --install Ubuntu-24.04 --name scout --location $Location --no-launch
    if ($LASTEXITCODE -ne 0) { throw "wsl --install не удался" }
} else { Say "1/4 Linux 'scout' уже есть" }

Say "2/4 ставлю MongoDB и Scout внутри 'scout'"
wsl.exe -d scout -u root bash "$Kit/install_inside.sh"
if ($LASTEXITCODE -ne 0) { throw "install_inside.sh завершился с ошибкой" }

Say "3/4 перезапуск 'scout' с systemd и фоновый keep-alive"
wsl.exe --terminate scout
$Startup = [Environment]::GetFolderPath("Startup")
$Vbs = Join-Path $Startup "scout_keepalive.vbs"
Set-Content -Path $Vbs -Encoding ASCII -Value 'CreateObject("WScript.Shell").Run "wsl.exe -d scout -u root --exec sleep infinity", 0, False'
Start-Process wscript.exe -ArgumentList "`"$Vbs`""
Start-Sleep -Seconds 8

$cases = wsl.exe -d scout -u root bash -c "mongosh -quiet scout --eval 'db.hgnc_gene.estimatedDocumentCount()' 2>/dev/null"
if ([int]("0" + ($cases -replace '\D', '')) -gt 0) {
    Say "4/4 база Scout уже заполнена, пропускаю"
} else {
    Say "4/4 заполняю базу: гены, HPO, Orphanet, OMIM (~20-40 минут)"
    wsl.exe -d scout -u root bash "$Kit/setup_db.sh"
    if ($LASTEXITCODE -ne 0) { throw "setup_db.sh завершился с ошибкой" }
}
Say "Готово. Открыть Scout: http://localhost:8000 (вход: admin@arcgen.local)"
Say "Загрузить прогон: wsl -d scout -u root bash $Kit/scout_load.sh 2026-10-22_SAMPLE03_M"
