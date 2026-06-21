import 'dart:async';

/// Açılış temizliği (çökme sonrası sıfırlama) bitene kadar dinleyicilerin
/// bayat davetleri işlemesini geciktirmek için kullanılan basit kapı.
///
/// UI hemen açılır; ağ/temizlik işleri arka planda yürür. Bu kapı, sıralamayı
/// bozmadan "önce temizlik, sonra otomatik bağlanma" garantisini sağlar.
class StartupGate {
  StartupGate._();

  static final Completer<void> _completer = Completer<void>();

  /// Temizlik tamamlandığında biten future.
  static Future<void> get ready => _completer.future;

  static bool get isReady => _completer.isCompleted;

  /// Açılış temizliği bitti — bekleyenler devam edebilir.
  static void markReady() {
    if (!_completer.isCompleted) {
      _completer.complete();
    }
  }

  /// Kapıyı bir zaman aşımıyla bekler; süre dolarsa yine de devam eder.
  static Future<void> waitReady({
    Duration timeout = const Duration(seconds: 12),
  }) {
    if (_completer.isCompleted) return Future<void>.value();
    return ready.timeout(timeout, onTimeout: () {});
  }
}
