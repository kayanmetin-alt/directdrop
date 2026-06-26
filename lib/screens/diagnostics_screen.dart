import 'dart:async';
import 'dart:io';

import 'package:firebase_auth/firebase_auth.dart';
import 'package:firebase_core/firebase_core.dart';
import 'package:firebase_database/firebase_database.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:share_plus/share_plus.dart';

import '../services/device_identity_service.dart';
import '../services/device_registry_service.dart';
import '../services/firebase_auth_service.dart';
import '../services/firebase_rtdb_service.dart';

/// Windows başta olmak üzere tüm platformlarda Firebase/RTDB bağlantısını
/// adım adım test edip tam hata kodunu ekranda gösterir. "Sunucuya bağlanılamadı"
/// gibi genel mesajların ardındaki gerçek nedeni (auth, izin, ağ, SDK) ortaya çıkarır.
class DiagnosticsScreen extends StatefulWidget {
  const DiagnosticsScreen({super.key});

  @override
  State<DiagnosticsScreen> createState() => _DiagnosticsScreenState();
}

class _DiagStep {
  _DiagStep(this.title);
  final String title;
  _DiagStatus status = _DiagStatus.pending;
  String detail = '';
}

enum _DiagStatus { pending, running, ok, fail }

class _DiagnosticsScreenState extends State<DiagnosticsScreen> {
  final List<_DiagStep> _steps = [
    _DiagStep('Firebase başlatıldı'),
    _DiagStep('Anonim oturum (Auth)'),
    _DiagStep('Kimlik jetonu (ID token)'),
    _DiagStep('RTDB bağlantı durumu (.info/connected)'),
    _DiagStep('Cihaz kaydı (gerçek uygulama akışı)'),
    _DiagStep('RTDB okuma (kendi cihaz düğümü)'),
    _DiagStep('Sunucu zaman damgası yazma'),
    _DiagStep('onDisconnect kaydı'),
  ];

  bool _running = false;
  String _summary = '';

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) => _run());
  }

  String _describeError(Object e) {
    if (e is FirebaseException) {
      final msg = e.message ?? '';
      // code=unknown'da message boş gelir; ham metin gerçek nedeni gösterir.
      final extra = msg.isEmpty ? e.toString() : msg;
      return 'FirebaseException(code=${e.code}, plugin=${e.plugin})\n$extra';
    }
    final text = e.toString();
    return '${e.runtimeType}: $text';
  }

  Future<void> _set(int i, _DiagStatus status, [String detail = '']) async {
    if (!mounted) return;
    setState(() {
      _steps[i].status = status;
      if (detail.isNotEmpty) _steps[i].detail = detail;
    });
  }

  Future<void> _run() async {
    if (_running) return;
    setState(() {
      _running = true;
      _summary = '';
      for (final s in _steps) {
        s.status = _DiagStatus.pending;
        s.detail = '';
      }
    });

    var firstFailure = '';

    // 1) Firebase başlatıldı mı?
    await _set(0, _DiagStatus.running);
    if (Firebase.apps.isNotEmpty) {
      await _set(0, _DiagStatus.ok, 'app: ${Firebase.apps.first.name}');
    } else {
      await _set(0, _DiagStatus.fail, 'Firebase.apps boş — başlatma başarısız.');
      firstFailure = 'Firebase başlatılamadı.';
    }

    // 2) Anonim oturum
    String? uid;
    await _set(1, _DiagStatus.running);
    try {
      await FirebaseAuthService.instance.ensureSignedIn();
      uid = FirebaseAuth.instance.currentUser?.uid;
      if (uid == null) {
        await _set(1, _DiagStatus.fail, 'currentUser null (oturum açılmadı).');
        firstFailure = firstFailure.isEmpty ? 'Auth oturumu yok.' : firstFailure;
      } else {
        await _set(1, _DiagStatus.ok, 'uid: $uid');
      }
    } catch (e) {
      await _set(1, _DiagStatus.fail, _describeError(e));
      firstFailure = firstFailure.isEmpty ? 'Auth hatası.' : firstFailure;
    }

    // 3) ID token
    await _set(2, _DiagStatus.running);
    try {
      final token =
          await FirebaseAuth.instance.currentUser?.getIdToken(true);
      if (token == null || token.isEmpty) {
        await _set(2, _DiagStatus.fail, 'Jeton boş döndü.');
      } else {
        await _set(2, _DiagStatus.ok, 'uzunluk: ${token.length} karakter');
      }
    } catch (e) {
      await _set(2, _DiagStatus.fail, _describeError(e));
    }

    final db = FirebaseRtdbService.database;

    // 4) .info/connected — websocket bağlantı durumu.
    // ÖNEMLİ: `.get()` KULLANMA. iOS'ta `.get()` REST üzerinden okur ve
    // `/.info/connected` için kural olmadığından her zaman permission-denied
    // döner (yanlış negatif). Gerçek bağlantı durumu yalnızca dinleyiciyle
    // (onValue) güvenilir okunur.
    await _set(3, _DiagStatus.running);
    try {
      final event = await db
          .ref('.info/connected')
          .onValue
          .firstWhere((e) => e.snapshot.value == true)
          .timeout(const Duration(seconds: 12));
      await _set(3, _DiagStatus.ok, 'connected: ${event.snapshot.value}');
    } catch (e) {
      await _set(3, _DiagStatus.fail, _describeError(e));
      firstFailure =
          firstFailure.isEmpty ? 'RTDB sunucusuna ulaşılamıyor.' : firstFailure;
    }

    // 5) Gerçek cihaz kaydı — uygulamanın kullandığı akışın aynısı.
    // Kök `devices/{id}` düğümünü `ownerUid` ile yazar; güvenlik kuralları
    // tam olarak bunu bekler. Bu adım OK ise RTDB yazma gerçekten çalışıyor.
    final deviceId = await DeviceIdentityService.instance.getDeviceId();
    final selfRef = db.ref('devices').child(deviceId);
    await _set(4, _DiagStatus.running);
    try {
      await DeviceRegistryService()
          .registerCurrentDevice()
          .timeout(const Duration(seconds: 15));
      await _set(4, _DiagStatus.ok, 'kayıt başarılı: devices/$deviceId');
    } catch (e) {
      await _set(4, _DiagStatus.fail, _describeError(e));
      firstFailure =
          firstFailure.isEmpty ? 'Cihaz kaydı (RTDB yazma) başarısız.' : firstFailure;
    }

    // 6) RTDB okuma — artık kendi düğümümüz var, sahibi biziz.
    await _set(5, _DiagStatus.running);
    try {
      final snap =
          await selfRef.get().timeout(const Duration(seconds: 12));
      await _set(5, _DiagStatus.ok, 'okuma başarılı (exists: ${snap.exists})');
    } catch (e) {
      await _set(5, _DiagStatus.fail, _describeError(e));
      firstFailure = firstFailure.isEmpty ? 'RTDB okuma reddedildi/başarısız.' : firstFailure;
    }

    // 7) Sunucu zaman damgası — sahip olduğumuz düğümde update.
    await _set(6, _DiagStatus.running);
    try {
      await selfRef
          .update({'lastSeen': ServerValue.timestamp})
          .timeout(const Duration(seconds: 12));
      await _set(6, _DiagStatus.ok, 'ServerValue.timestamp yazıldı');
    } catch (e) {
      await _set(6, _DiagStatus.fail, _describeError(e));
    }

    // 8) onDisconnect — gerçek uygulamanın kurduğu handler ile aynı.
    await _set(7, _DiagStatus.running);
    try {
      await selfRef
          .child('online')
          .onDisconnect()
          .set(false)
          .timeout(const Duration(seconds: 12));
      await selfRef.child('online').onDisconnect().cancel();
      await _set(7, _DiagStatus.ok, 'onDisconnect set+cancel başarılı');
    } catch (e) {
      await _set(7, _DiagStatus.fail, _describeError(e));
    }

    if (!mounted) return;
    setState(() {
      _running = false;
      final failed = _steps.where((s) => s.status == _DiagStatus.fail).length;
      _summary = failed == 0
          ? 'Tüm testler başarılı. RTDB bu cihazda çalışıyor.'
          : 'İlk hata: $firstFailure  ($failed test başarısız)';
    });
  }

  String _buildReport() {
    final buffer = StringBuffer()
      ..writeln('DirectDrop Tanılama — ${Platform.operatingSystem} '
          '${Platform.operatingSystemVersion}')
      ..writeln('Zaman: ${DateTime.now().toIso8601String()}')
      ..writeln('Özet: $_summary')
      ..writeln('');
    for (final s in _steps) {
      final mark = switch (s.status) {
        _DiagStatus.ok => 'OK ',
        _DiagStatus.fail => 'HATA',
        _DiagStatus.running => '... ',
        _DiagStatus.pending => '-   ',
      };
      buffer.writeln('[$mark] ${s.title}');
      if (s.detail.isNotEmpty) {
        buffer.writeln('       ${s.detail.replaceAll('\n', '\n       ')}');
      }
    }
    return buffer.toString();
  }

  Future<void> _copyReport() async {
    await Clipboard.setData(ClipboardData(text: _buildReport()));
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(content: Text('Rapor panoya kopyalandı')),
    );
  }

  Future<void> _shareReport() async {
    try {
      await SharePlus.instance.share(
        ShareParams(
          text: _buildReport(),
          subject: 'DirectDrop Bağlantı Tanılama Raporu',
        ),
      );
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Paylaşılamadı: $e')),
      );
    }
  }

  Color _statusColor(_DiagStatus status, ThemeData theme) {
    return switch (status) {
      _DiagStatus.ok => Colors.green,
      _DiagStatus.fail => theme.colorScheme.error,
      _DiagStatus.running => theme.colorScheme.primary,
      _DiagStatus.pending => theme.colorScheme.onSurfaceVariant,
    };
  }

  IconData _statusIcon(_DiagStatus status) {
    return switch (status) {
      _DiagStatus.ok => Icons.check_circle,
      _DiagStatus.fail => Icons.error,
      _DiagStatus.running => Icons.hourglass_top,
      _DiagStatus.pending => Icons.circle_outlined,
    };
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Scaffold(
      appBar: AppBar(
        title: const Text('Bağlantı Tanılama'),
        actions: [
          IconButton(
            icon: const Icon(Icons.ios_share),
            tooltip: 'Raporu paylaş',
            onPressed: _shareReport,
          ),
          IconButton(
            icon: const Icon(Icons.copy_all),
            tooltip: 'Raporu kopyala',
            onPressed: _copyReport,
          ),
        ],
      ),
      body: SafeArea(
        child: Column(
          children: [
            if (_summary.isNotEmpty)
              Container(
                width: double.infinity,
                color: _steps.any((s) => s.status == _DiagStatus.fail)
                    ? theme.colorScheme.errorContainer
                    : Colors.green.withValues(alpha: 0.15),
                padding: const EdgeInsets.all(12),
                child: Text(
                  _summary,
                  style: theme.textTheme.bodyMedium?.copyWith(
                    fontWeight: FontWeight.w600,
                  ),
                ),
              ),
            Expanded(
              child: ListView.separated(
                padding: const EdgeInsets.all(12),
                itemCount: _steps.length,
                separatorBuilder: (_, __) => const Divider(height: 1),
                itemBuilder: (context, i) {
                  final s = _steps[i];
                  return ListTile(
                    leading: Icon(
                      _statusIcon(s.status),
                      color: _statusColor(s.status, theme),
                    ),
                    title: Text('${i + 1}. ${s.title}'),
                    subtitle: s.detail.isEmpty
                        ? null
                        : SelectableText(
                            s.detail,
                            style: theme.textTheme.bodySmall?.copyWith(
                              fontFamily: 'monospace',
                            ),
                          ),
                  );
                },
              ),
            ),
            Padding(
              padding: const EdgeInsets.all(12),
              child: Row(
                children: [
                  Expanded(
                    child: FilledButton.icon(
                      onPressed: _running ? null : _run,
                      icon: _running
                          ? const SizedBox(
                              width: 18,
                              height: 18,
                              child: CircularProgressIndicator(strokeWidth: 2),
                            )
                          : const Icon(Icons.refresh),
                      label: Text(_running ? 'Çalışıyor…' : 'Yeniden çalıştır'),
                    ),
                  ),
                  const SizedBox(width: 12),
                  FilledButton.tonalIcon(
                    onPressed: _shareReport,
                    icon: const Icon(Icons.ios_share),
                    label: const Text('Paylaş'),
                  ),
                  const SizedBox(width: 8),
                  OutlinedButton.icon(
                    onPressed: _copyReport,
                    icon: const Icon(Icons.copy_all),
                    label: const Text('Kopyala'),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}
