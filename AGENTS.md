# DirectDrop

Cross-platform peer-to-peer (P2P) file transfer app built with **Flutter** (Dart). Devices pair via a 6-digit room code / QR, exchange WebRTC signaling through **Firebase Realtime Database**, then transfer files device-to-device over a **WebRTC Data Channel** in 64 KB chunks with SHA-256 verification. Target platforms: iOS, Android, macOS, Windows. The committed `lib/firebase_options.dart` and `android/app/google-services.json` point at the live Firebase project (`personaltrainer-77e4c`); there is no local emulator. `functions/` holds optional Node.js 20 Cloud Functions (push "wake"); `fastlane/` + `.github/workflows/` handle store releases.

Standard commands are documented in `README.md` (Turkish), `setup.sh`, and the GitHub Actions workflows under `.github/workflows/`.

## Cursor Cloud specific instructions

The update script runs `flutter pub get`. Flutter SDK (stable, installed at `~/flutter`) and the Android SDK (`~/android-sdk`) are baked into the VM snapshot; their `PATH`/`ANDROID_SDK_ROOT` are exported in `~/.bashrc`. Non-interactive shells may not source `~/.bashrc`, so prefer absolute paths (e.g. `~/flutter/bin/flutter`) or run via a login/interactive bash.

- **Lint:** `flutter analyze` (config in `analysis_options.yaml`).
- **Test:** `flutter test` (only `test/room_code_generator_test.dart` exists).
- **Build:** `flutter build apk --debug` is the verified, buildable target on this Linux VM. Android licenses are pre-accepted; the first Gradle build auto-downloads extra SDK platforms (34/35) and CMake.

Platform/run constraints on this headless Linux VM (do not waste time re-trying these):
- **Android emulator does not run** — there is no `/dev/kvm` and no CPU virtualization, so no AVD can boot.
- **Web is unsupported by the app itself** — `lib/firebase_options.dart` throws `UnsupportedError('Web henüz desteklenmiyor.')`, and desktop-only plugins (`window_manager`, `tray_manager`, `screen_retriever`) have no web support.
- **Linux desktop is not a target** — there is no `linux/` directory, and the Firebase plugins have no Linux desktop implementation.
- Building Android (`flutter build apk`) is therefore the canonical "the app compiles into a runnable artifact" check. The GUI cannot be launched here; verify core logic by exercising the pure-Dart modules in `lib/utils` and `lib/models` (e.g. `RoomCodeGenerator`, `InviteCodeParser`, `FileHasher`, `SignalingMessage`) via `dart run` / `flutter test`.

Notes:
- `flutter pub get` may leave `pubspec.lock` dirty (transitive `matcher`/`meta`/`test_api` bumps) and the first Android build may add Flutter-migrator flags to `android/gradle.properties`; these are incidental and should not be committed.
- `functions/` (Cloud Functions) and `fastlane/` are deploy-only and not needed to lint/test/build the app locally.
