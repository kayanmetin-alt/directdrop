import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// Geliştirici araçlarını (bağlantı tanılama vb.) son kullanıcıdan gizler.
///
/// Akış:
/// 1. Ana ekrandaki sürüm etiketine arka arkaya [_tapsToUnlock] kez dokununca
///    "geliştirici modu" kilidi açılır ([unlocked] = true) ve araçlar açılır.
/// 2. Kilit açıldığında Ayarlar'da "Geliştirici Araçları" anahtarı görünür;
///    buradan araçlar açılıp kapatılabilir ([toolsEnabled]).
/// 3. "Geliştirici modunu kapat" ile kilit tamamen kapatılır; anahtar yeniden
///    gizlenir ve uygulama son kullanıcı görünümüne döner.
class DeveloperModeService extends ChangeNotifier {
  DeveloperModeService._();

  static final DeveloperModeService instance = DeveloperModeService._();

  static const _unlockedKey = 'directdrop_dev_mode_unlocked';
  static const _toolsEnabledKey = 'directdrop_dev_tools_enabled';

  /// Kilidi açmak için gereken art arda dokunuş sayısı.
  static const _tapsToUnlock = 7;

  /// Dokunuşların "art arda" sayılması için izin verilen en uzun ara.
  static const _tapWindow = Duration(milliseconds: 1500);

  bool _loaded = false;
  bool _unlocked = false;
  bool _toolsEnabled = false;

  int _tapCount = 0;
  DateTime? _lastTap;

  bool get unlocked => _unlocked;

  /// Araçların şu an görünür olup olmadığı (kilit açık VE anahtar açık).
  bool get toolsEnabled => _unlocked && _toolsEnabled;

  Future<void> load() async {
    if (_loaded) return;
    final prefs = await SharedPreferences.getInstance();
    _unlocked = prefs.getBool(_unlockedKey) ?? false;
    _toolsEnabled = prefs.getBool(_toolsEnabledKey) ?? false;
    _loaded = true;
    notifyListeners();
  }

  /// Sürüm etiketine her dokunuşta çağrılır.
  ///
  /// - Kilit yeni açıldıysa [_TapResult.unlocked] döner (snackbar gösterilebilir).
  /// - Açılmaya yaklaşıldıysa [_TapResult.progress] ile kalan dokunuş sayısı döner.
  /// - Aksi halde [_TapResult.none].
  DeveloperTapResult registerSecretTap() {
    if (_unlocked) return const DeveloperTapResult.none();

    final now = DateTime.now();
    if (_lastTap == null || now.difference(_lastTap!) > _tapWindow) {
      _tapCount = 0;
    }
    _lastTap = now;
    _tapCount++;

    if (_tapCount >= _tapsToUnlock) {
      _tapCount = 0;
      unawaited(_setUnlocked(true, enableTools: true));
      return const DeveloperTapResult.unlocked();
    }

    final remaining = _tapsToUnlock - _tapCount;
    // İlk birkaç dokunuşta ipucu verme; sona yaklaşınca göster.
    if (remaining <= 3) {
      return DeveloperTapResult.progress(remaining);
    }
    return const DeveloperTapResult.none();
  }

  Future<void> setToolsEnabled(bool enabled) async {
    if (!_unlocked) return;
    _toolsEnabled = enabled;
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool(_toolsEnabledKey, enabled);
    notifyListeners();
  }

  /// Geliştirici modunu tamamen kapatır (son kullanıcı görünümüne döner).
  Future<void> lock() => _setUnlocked(false, enableTools: false);

  Future<void> _setUnlocked(bool value, {required bool enableTools}) async {
    _unlocked = value;
    _toolsEnabled = enableTools;
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool(_unlockedKey, value);
    await prefs.setBool(_toolsEnabledKey, enableTools);
    notifyListeners();
  }
}

/// Gizli dokunuşun sonucu.
class DeveloperTapResult {
  const DeveloperTapResult.none()
      : unlockedNow = false,
        remaining = null;
  const DeveloperTapResult.unlocked()
      : unlockedNow = true,
        remaining = null;
  const DeveloperTapResult.progress(this.remaining) : unlockedNow = false;

  final bool unlockedNow;
  final int? remaining;
}
