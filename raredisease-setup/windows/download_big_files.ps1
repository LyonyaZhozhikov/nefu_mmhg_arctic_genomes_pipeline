# Download the BIG reference files for nf-core/raredisease (GRCh38) on any Windows PC, no WSL needed.
# Only the files that `PART=small` skips on the lab PC: CADD v1.7 and gnomAD v4.1 genomes (~1 TB total).
#
# Run in PowerShell (no admin needed):
#   powershell -ExecutionPolicy Bypass -File download_big_files.ps1            # saves to E:\raredisease_big
#   powershell -ExecutionPolicy Bypass -File download_big_files.ps1 -Dest F:\x  # another folder
#
# Safe to stop and re-run at any time: finished files are skipped, a half-done file resumes where it stopped.
# Order = priority: CADD SNV scores, CADD indel prescored, gnomAD by chromosome, then the 335 GB CADD
# annotation archive last. On the lab PC the setup scripts read these files from the disk instead of downloading.
param([string]$Dest = "E:\raredisease_big")

$cadd   = "https://kircherlab.bihealth.org/download/CADD/v1.7/GRCh38"
$gnomad = "https://storage.googleapis.com/gcp-public-data--gnomad/release/4.1/vcf/genomes"

$files = @(
  @{ url = "$cadd/whole_genome_SNVs.tsv.gz";               dir = "cadd";   gb = 81.5 },
  @{ url = "$cadd/whole_genome_SNVs.tsv.gz.tbi";           dir = "cadd";   gb = 0 },
  @{ url = "$cadd/whole_genome_SNVs.tsv.gz.md5";           dir = "cadd";   gb = 0 },
  @{ url = "$cadd/gnomad.genomes.r4.0.indel.tsv.gz";       dir = "cadd";   gb = 1.2 },
  @{ url = "$cadd/gnomad.genomes.r4.0.indel.tsv.gz.tbi";   dir = "cadd";   gb = 0 }
)
foreach ($c in (1..22 + "X", "Y")) {
  $files += @{ url = "$gnomad/gnomad.genomes.v4.1.sites.chr$c.vcf.bgz"; dir = "gnomad"; gb = 0 }
}
$files += @{ url = "$cadd/GRCh38_v1.7.tar.gz";     dir = "cadd"; gb = 335 }
$files += @{ url = "$cadd/GRCh38_v1.7.tar.gz.md5"; dir = "cadd"; gb = 0 }

$drive = (Split-Path -Qualifier $Dest)
$free  = (Get-PSDrive ($drive.TrimEnd(':'))).Free / 1GB
Write-Host ("Папка: {0}   свободно на диске: {1:N0} ГБ   нужно всего: ~1025 ГБ" -f $Dest, $free)
if ($free -lt 1030) { Write-Host "ВНИМАНИЕ: места на всё не хватит. Скачаю по порядку, сколько поместится." -ForegroundColor Yellow }

foreach ($f in $files) {
  $dir  = Join-Path $Dest $f.dir
  New-Item -ItemType Directory -Force $dir | Out-Null
  $name = ($f.url -split '/')[-1]
  $out  = Join-Path $dir $name
  $done = "$out.done"
  if (Test-Path $done) { Write-Host "уже есть: $name"; continue }
  Write-Host "`n=== $name" -ForegroundColor Cyan
  # -C - resumes a partial file; retries ride out short network drops
  & curl.exe -L -C - --retry 20 --retry-delay 30 --retry-all-errors -o $out $f.url
  if ($LASTEXITCODE -eq 0) { New-Item -ItemType File $done | Out-Null }
  else { Write-Host "Ошибка $LASTEXITCODE на $name. Запустите скрипт ещё раз, он продолжит." -ForegroundColor Red; exit 1 }
}

# Check CADD archives against the published MD5 sums (takes a while for 335 GB)
foreach ($n in "whole_genome_SNVs.tsv.gz", "GRCh38_v1.7.tar.gz") {
  $p = Join-Path $Dest "cadd\$n"
  if ((Test-Path $p) -and (Test-Path "$p.md5")) {
    Write-Host "Проверяю MD5: $n ..."
    $want = ((Get-Content "$p.md5" -Raw) -split '\s+')[0].ToLower()
    $have = (Get-FileHash $p -Algorithm MD5).Hash.ToLower()
    if ($want -eq $have) { Write-Host "  OK" -ForegroundColor Green } else { Write-Host "  НЕ СОВПАДАЕТ: удалите $p и $p.done и запустите снова" -ForegroundColor Red }
  }
}
Write-Host "`nГотово. Всё лежит в $Dest" -ForegroundColor Green
