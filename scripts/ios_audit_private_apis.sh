#!/usr/bin/env bash
# App Store 2.5.1 taraması: binary içinde deprecated/private API izlerini listeler.
set -euo pipefail

APP_PATH="${1:-build/ios/iphoneos/Runner.app}"
if [[ ! -d "$APP_PATH" ]]; then
  echo "Kullanım: $0 [Runner.app yolu]" >&2
  echo "Önce: flutter build ios --release --no-codesign" >&2
  exit 1
fi

PATTERNS='mainScreen|sharedApplication|PGHostedWindow|__SwiftValue|UIStatusBarStyle|initForMainScreen|statusBarStyle|willChangeStatusBar|didChangeStatusBar|LSApplicationWorkspace|_statusBar'

echo "=== DirectDrop iOS API denetimi ==="
echo "App: $APP_PATH"
echo ""

scan_binary() {
  local label="$1"
  local file="$2"
  if ! file "$file" | grep -qE 'Mach-O|ar archive'; then
    return
  fi
  local hits
  hits=$(strings "$file" 2>/dev/null | rg -i "$PATTERNS" | sort -u || true)
  if [[ -n "$hits" ]]; then
    echo ">>> $label"
    echo "$hits"
    echo ""
  fi
}

scan_binary "Runner" "$APP_PATH/Runner"
while IFS= read -r fw; do
  scan_binary "$(basename "$fw")" "$fw"
done < <(find "$APP_PATH/Frameworks" -type f -maxdepth 2 2>/dev/null)

echo "=== nm (Runner) — UIScreen / UIApplication ==="
nm -u "$APP_PATH/Runner" 2>/dev/null | rg 'UIScreen|UIApplication|StatusBar|mainScreen|sharedApplication' || true

echo ""
echo "=== WebRTC-SDK sürümü (Podfile.lock) ==="
rg 'WebRTC-SDK' ios/Podfile.lock || true
