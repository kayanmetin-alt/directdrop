#!/usr/bin/env bash
# DirectDrop mağaza ekran görüntüleri — iOS, Android, macOS simülatörlerinden.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"

export ANDROID_HOME="${ANDROID_HOME:-$HOME/Library/Android/sdk}"
export PATH="$ANDROID_HOME/platform-tools:$ANDROID_HOME/emulator:$PATH"

IOS_UDID="${IOS_UDID:-4C164EEE-14F0-4D7C-8F3A-F3154CA09E06}" # iPhone 15 Pro Max
ANDROID_ID="${ANDROID_ID:-emulator-5554}"
BUNDLE_ID="com.directdrop.app"

IOS_OUT="$ROOT/fastlane/screenshots/tr"
ANDROID_OUT="$ROOT/store/screenshots/play-store"
MACOS_OUT="$ROOT/store/screenshots/mac-app-store"
STORE_IOS_OUT="$ROOT/store/screenshots/app-store"

READY_FILE="/tmp/directdrop_screenshot_ready"
ROOM_CODE_FILE="/tmp/directdrop_room_code.txt"

DART_DEFINES=(
  "--dart-define=SCREENSHOT_STEP="
)

mkdir -p "$IOS_OUT" "$ANDROID_OUT" "$MACOS_OUT" "$STORE_IOS_OUT"

log() { printf '\n[%s] %s\n' "$(date +%H:%M:%S)" "$*"; }

kill_flutter() {
  pkill -f "flutter run.*SCREENSHOT_STEP" 2>/dev/null || true
  sleep 1
}

reset_signals() {
  rm -f "$READY_FILE" "$ROOM_CODE_FILE"
}

clear_ios() {
  log "iOS uygulama verisi temizleniyor…"
  xcrun simctl uninstall "$IOS_UDID" "$BUNDLE_ID" 2>/dev/null || true
}

clear_android() {
  log "Android uygulama verisi temizleniyor…"
  adb -s "$ANDROID_ID" shell pm clear "$BUNDLE_ID" 2>/dev/null || true
}

clear_macos() {
  log "macOS uygulama verisi temizleniyor…"
  defaults delete "$BUNDLE_ID" 2>/dev/null || true
  rm -rf "$HOME/Library/Containers/$BUNDLE_ID" 2>/dev/null || true
  rm -rf "$HOME/Library/Group Containers/"*directdrop* 2>/dev/null || true
}

boot_ios() {
  log "iOS simülatör başlatılıyor ($IOS_UDID)…"
  xcrun simctl boot "$IOS_UDID" 2>/dev/null || true
  open -a Simulator --args -CurrentDeviceUDID "$IOS_UDID"
  xcrun simctl bootstatus "$IOS_UDID" -b
}

boot_android() {
  log "Android emülatör kontrol…"
  if adb devices 2>/dev/null | rg -q "emulator-[0-9]+\\s+device"; then
    ANDROID_ID="$(adb devices | rg 'emulator-[0-9]+' | head -1 | awk '{print $1}')"
    log "Çalışan emülatör kullanılıyor: $ANDROID_ID"
    return 0
  fi
  "$ANDROID_HOME/emulator/emulator" -avd Pixel_7 -no-snapshot-load -no-audio -no-boot-anim &
  adb wait-for-device
  ANDROID_ID="$(adb devices | rg 'emulator-[0-9]+' | head -1 | awk '{print $1}')"
  for _ in $(seq 1 60); do
    boot=$(adb -s "$ANDROID_ID" shell getprop sys.boot_completed 2>/dev/null | tr -d '\r')
    [[ "$boot" == "1" ]] && break
    sleep 2
  done
}

wait_ready() {
  local timeout="${1:-90}"
  for _ in $(seq 1 "$timeout"); do
    [[ -f "$READY_FILE" ]] && return 0
    sleep 1
  done
  return 1
}

run_step() {
  local device="$1"
  local step="$2"
  reset_signals
  log "flutter run ($device, step=$step)"
  flutter run -d "$device" \
    --dart-define="SCREENSHOT_STEP=$step" \
    > "/tmp/directdrop_flutter_${device}_${step}.log" 2>&1 &
  RUN_STEP_PID=$!
  if ! wait_ready 120; then
    kill "$RUN_STEP_PID" 2>/dev/null || true
    tail -40 "/tmp/directdrop_flutter_${device}_${step}.log" || true
    die "Hazır sinyali gelmedi (step=$step, device=$device)"
  fi
  sleep 1
}

stop_run_step() {
  if [[ -n "${RUN_STEP_PID:-}" ]]; then
    kill "$RUN_STEP_PID" 2>/dev/null || true
    wait "$RUN_STEP_PID" 2>/dev/null || true
    RUN_STEP_PID=""
  fi
}

capture_ios() {
  local out="$1"
  xcrun simctl io "$IOS_UDID" screenshot "$out"
}

capture_android() {
  local out="$1"
  adb -s "$ANDROID_ID" exec-out screencap -p > "$out"
}

capture_macos_window() {
  local out="$1"
  local app="directdrop"
  sleep 1
  local wid
  wid=$(osascript <<'APPLESCRIPT'
tell application "System Events"
  repeat with i from 1 to 40
    if exists (first process whose name is "directdrop") then
      tell process "directdrop"
        return id of window 1
      end tell
    end if
    delay 0.25
  end repeat
end tell
APPLESCRIPT
) || true
  if [[ -n "${wid:-}" ]]; then
    screencapture -x -l "$wid" "$out"
  else
    screencapture -x -R100,80,1280,800 "$out"
  fi
}

resize_ios() {
  local file="$1"
  # App Store 6.5" — 1284×2778
  sips --resampleHeightWidth 2778 1284 "$file" >/dev/null
}

resize_android() {
  local file="$1"
  # Play Store telefon — 1080×1920 (9:16)
  sips --resampleHeightWidth 1920 1080 "$file" >/dev/null
}

resize_macos() {
  local file="$1"
  # Mac App Store — 1280×800
  sips --resampleHeightWidth 800 1280 "$file" >/dev/null
}

die() {
  log "HATA: $*"
  kill_flutter
  exit 1
}

shot_single() {
  local platform="$1"
  local step="$2"
  local filename="$3"
  local device="$4"

  run_step "$device" "$step"

  case "$platform" in
    ios)
      capture_ios "$IOS_OUT/$filename"
      cp "$IOS_OUT/$filename" "$STORE_IOS_OUT/$filename"
      resize_ios "$IOS_OUT/$filename"
      resize_ios "$STORE_IOS_OUT/$filename"
      ;;
    android)
      capture_android "$ANDROID_OUT/$filename"
      resize_android "$ANDROID_OUT/$filename"
      ;;
    macos)
      capture_macos_window "$MACOS_OUT/$filename"
      resize_macos "$MACOS_OUT/$filename"
      ;;
  esac
  stop_run_step
  log "Kaydedildi: $filename ($platform)"
}

shot_transfer_pair() {
  local host_platform="$1"
  local guest_platform="$2"
  local host_device="$3"
  local guest_device="$4"
  local host_file="$5"
  local guest_file="$6"

  reset_signals
  kill_flutter

  log "Transfer: $host_platform (host) + $guest_platform (guest)"

  flutter run -d "$host_device" \
    --dart-define=SCREENSHOT_STEP=host_daemon \
    > "/tmp/directdrop_host_daemon.log" 2>&1 &
  local host_pid=$!

  for _ in $(seq 1 90); do
    [[ -f "$ROOM_CODE_FILE" ]] && break
    sleep 1
  done
  [[ -f "$ROOM_CODE_FILE" ]] || die "Oda kodu oluşmadı"

  flutter run -d "$guest_device" \
    --dart-define=SCREENSHOT_STEP=join_connect \
    > "/tmp/directdrop_join_connect.log" 2>&1 &
  local guest_pid=$!

  for _ in $(seq 1 120); do
    if [[ -f "$READY_FILE" ]]; then
      break
    fi
    sleep 1
  done

  sleep 2

  case "$host_platform" in
    ios)
      capture_ios "$IOS_OUT/$host_file"
      cp "$IOS_OUT/$host_file" "$STORE_IOS_OUT/$host_file"
      resize_ios "$IOS_OUT/$host_file"
      resize_ios "$STORE_IOS_OUT/$host_file"
      ;;
    macos)
      capture_macos_window "$MACOS_OUT/$host_file"
      resize_macos "$MACOS_OUT/$host_file"
      ;;
  esac

  case "$guest_platform" in
    android)
      capture_android "$ANDROID_OUT/$guest_file"
      resize_android "$ANDROID_OUT/$guest_file"
      ;;
    ios)
      capture_ios "$IOS_OUT/$guest_file"
      cp "$IOS_OUT/$guest_file" "$STORE_IOS_OUT/$guest_file"
      resize_ios "$IOS_OUT/$guest_file"
      resize_ios "$STORE_IOS_OUT/$guest_file"
      ;;
  esac

  kill "$host_pid" "$guest_pid" 2>/dev/null || true
  kill_flutter
  log "Transfer ekran görüntüleri: $host_file, $guest_file"
}

# --- main ---
log "DirectDrop mağaza ekran görüntüleri başlıyor"

boot_ios
boot_android

clear_ios
clear_android
clear_macos

kill_flutter
reset_signals

# iOS
shot_single ios home 01_home.png "$IOS_UDID"
shot_single ios host 02_host.png "$IOS_UDID"
shot_single ios join 03_join.png "$IOS_UDID"
shot_single ios settings 05_settings.png "$IOS_UDID"
shot_single ios about 06_about.png "$IOS_UDID"

# Android
clear_android
shot_single android home 01_home.png "$ANDROID_ID"
shot_single android host 02_host.png "$ANDROID_ID"
shot_single android join 03_join.png "$ANDROID_ID"
shot_single android settings 05_settings.png "$ANDROID_ID"
shot_single android about 06_about.png "$ANDROID_ID"

# macOS
clear_macos
shot_single macos home 01_home.png macos
shot_single macos host 02_host.png macos
shot_single macos join 03_join.png macos
shot_single macos settings 05_settings.png macos
shot_single macos about 06_about.png macos

# Bağlı transfer — iOS host + Android guest
clear_ios
clear_android
reset_signals
shot_transfer_pair ios android "$IOS_UDID" "$ANDROID_ID" 04_transfer.png 04_transfer.png

# macOS host + iOS guest (masaüstü ↔ telefon)
clear_ios
clear_macos
reset_signals
shot_transfer_pair macos ios macos "$IOS_UDID" 04_transfer.png 04_transfer_mac_ios.png

# Eski tr-TR klasörünü kaldır (fastlane tr bekliyor)
rm -rf "$ROOT/fastlane/screenshots/tr-TR"

log "Tamamlandı."
log "iOS: $IOS_OUT"
log "Android: $ANDROID_OUT"
log "macOS: $MACOS_OUT"

for f in "$IOS_OUT"/*.png "$ANDROID_OUT"/*.png "$MACOS_OUT"/*.png; do
  [[ -f "$f" ]] && sips -g pixelWidth -g pixelHeight "$f" 2>/dev/null | rg -N "pixel|/Users" || true
done
