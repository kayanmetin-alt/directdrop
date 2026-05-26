# DirectDrop Windows kurulum paketi (Setup.exe) oluşturur.
# Gereksinimler: Flutter SDK, Visual Studio 2022 (Desktop C++), Inno Setup 6
# Kullanım: powershell -ExecutionPolicy Bypass -File scripts\build_windows_installer.ps1

$ErrorActionPreference = "Stop"

$Root = Split-Path -Parent $PSScriptRoot
Set-Location $Root

Write-Host "==> Flutter bağımlılıkları"
flutter pub get

Write-Host "==> Windows release build"
flutter build windows --release

$ReleaseDir = Join-Path $Root "build\windows\x64\runner\Release"
if (-not (Test-Path (Join-Path $ReleaseDir "directdrop.exe"))) {
    throw "Build çıktısı bulunamadı: $ReleaseDir\directdrop.exe"
}

$IsccCandidates = @(
    "${env:ProgramFiles(x86)}\Inno Setup 6\ISCC.exe",
    "${env:ProgramFiles}\Inno Setup 6\ISCC.exe"
)
$Iscc = $IsccCandidates | Where-Object { Test-Path $_ } | Select-Object -First 1
if (-not $Iscc) {
    throw @"
Inno Setup 6 bulunamadı.
İndirin: https://jrsoftware.org/isdl.php
Kurulumdan sonra bu scripti tekrar çalıştırın.
"@
}

Write-Host "==> Kurulum paketi (Setup.exe)"
& $Iscc "windows\installer\directdrop.iss"

$Output = Get-ChildItem -Path (Join-Path $Root "dist\windows") -Filter "DirectDrop-Setup-*.exe" |
    Sort-Object LastWriteTime -Descending |
    Select-Object -First 1

Write-Host ""
Write-Host "Tamamlandı: $($Output.FullName)"
Write-Host "Bu dosyayı Windows bilgisayarlara kopyalayıp çift tıklayarak kurabilirsiniz."
