# pubspec.yaml sürümünü windows/installer/version.iss dosyasına yazar.
# Inno Setup bu dosyayı okuyarak DirectDrop-Setup-X.Y.Z.exe adını üretir.

$ErrorActionPreference = "Stop"

$Root = Split-Path -Parent $PSScriptRoot
$Pubspec = Join-Path $Root "pubspec.yaml"
$OutFile = Join-Path $Root "windows\installer\version.iss"

$Line = Get-Content $Pubspec | Select-String '^version:\s*(.+)$'
if (-not $Line) {
    throw "pubspec.yaml içinde version: satırı bulunamadı."
}

$Version = ($Line.Line -replace '^version:\s*', '').Split('+')[0].Trim()
Set-Content -Path $OutFile -Value "#define MyAppVersion `"$Version`"" -Encoding UTF8
Write-Host "version.iss yazıldı: MyAppVersion=$Version"
