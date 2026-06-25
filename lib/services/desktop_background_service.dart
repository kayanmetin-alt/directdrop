import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:tray_manager/tray_manager.dart';
import 'package:window_manager/window_manager.dart';

import '../models/paired_device.dart';
import '../models/reconnect_request.dart';
import 'active_session_registry.dart';
import 'desktop_overlay_service.dart';
import 'paired_devices_service.dart';
import 'recent_connection_service.dart';
import 'session_cleanup_service.dart';
import 'wake_listener_service.dart';

/// Windows görev çubuğu / macOS menü çubuğu simgesi ve pencere kapatma davranışı.
class DesktopBackgroundService extends ChangeNotifier
    with WindowListener, TrayListener {
  DesktopBackgroundService._();

  static final DesktopBackgroundService instance = DesktopBackgroundService._();

  static const _prefKey = 'directdrop_run_in_tray'; // eski tercih — artık kullanılmıyor

  bool _initialized = false;
  bool _trayActive = false;
  bool _isQuitting = false;
  bool _menuListenersAttached = false;

  // UI gerektiren eylemler (cihaz penceresi açma) main.dart tarafından bağlanır.
  void Function(PairedDevice peer)? onConnectToPeer;
  void Function(ReconnectRequest request)? onApproveReconnect;
  Future<void> Function()? onShowMainApp;
  void Function()? onMainWindowShown;
  Future<void> Function()? onMainWindowHidden;

  static bool get isSupported => Platform.isWindows || Platform.isMacOS;

  bool get isQuitting => _isQuitting;

  /// Masaüstünde her zaman menü çubuğu / bildirim alanında çalışır.
  bool get keepsRunningInBackground => isSupported;

  Future<void> load() async {
    if (!isSupported) return;
    // Eski sürümlerde kaydedilmiş tercihi temizle.
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.remove(_prefKey);
    } catch (_) {}
  }

  /// Pencere yöneticisi ve tepsi simgesini hazırlar.
  Future<void> initialize() async {
    if (!isSupported) return;

    await windowManager.ensureInitialized();
    windowManager.removeListener(this);
    windowManager.addListener(this);
    await windowManager.setPreventClose(true);

    if (!_initialized) {
      trayManager.removeListener(this);
      trayManager.addListener(this);
      // tray_manager macOS'ta ikonu rootBundle.load(iconPath) ile yükler ve
      // Windows'ta data/flutter_assets/<iconPath> yolundan okur; her iki durumda
      // da doğrudan ASSET yolu verilmelidir (mutlak dosya yolu değil).
      // macOS menü çubuğu monokrom template ikon ister (açık/koyu temaya uyum).
      final iconAsset = Platform.isMacOS
          ? 'assets/tray_icon_template.png'
          : 'assets/tray_icon.png';
      await trayManager.setIcon(iconAsset, isTemplate: Platform.isMacOS);
      await trayManager.setToolTip('DirectDrop');
      _initialized = true;
    }

    _attachMenuListeners();
    await _refreshTrayMenu();
    _trayActive = true;
  }

  /// Eşleşme/istek/cihaz listesi değiştikçe menüyü güncel tut.
  void _attachMenuListeners() {
    if (_menuListenersAttached) return;
    _menuListenersAttached = true;
    RecentConnectionService.instance.addListener(_onMenuStateChanged);
    PairedDevicesService.instance.addListener(_onMenuStateChanged);
  }

  void _onMenuStateChanged() {
    if (!_trayActive) return;
    unawaited(_refreshTrayMenu());
  }

  bool shouldSkipGracefulShutdownOnPause() => keepsRunningInBackground;

  Future<bool> isMainWindowHidden() async {
    if (!isSupported) return false;
    try {
      return !(await windowManager.isVisible());
    } catch (_) {
      return false;
    }
  }

  Future<void> showMainWindow({bool force = false}) async {
    if (!isSupported) return;
    if (!force && DesktopOverlayService.instance.isOverlayOnlySession) {
      return;
    }
    if (force) {
      await DesktopOverlayService.instance.hideOverlayToTray();
    }
    try {
      await windowManager.show();
      await windowManager.focus();
      if (Platform.isMacOS) {
        const channel = MethodChannel('com.directdrop.app/window');
        await channel.invokeMethod<void>('activate');
      }
    } catch (e, stack) {
      debugPrint('Pencere gösterilemedi: $e\n$stack');
    }
    await DesktopOverlayService.instance.suppressPanelsForVisibleMainWindow();
    onMainWindowShown?.call();
  }

  Future<void> hideMainWindow() async {
    if (!isSupported) return;
    try {
      await windowManager.hide();
    } catch (e, stack) {
      debugPrint('Pencere gizlenemedi: $e\n$stack');
    }
  }

  Future<void> quitApp() async {
    if (_isQuitting) return;
    _isQuitting = true;

    RecentConnectionService.instance.stopListening();
    await WakeListenerService.instance.stop();
    await ActiveSessionRegistry.instance.disconnectActive();
    await SessionCleanupService.instance.markGracefulShutdown();

    await _destroyTray();
    try {
      await windowManager.destroy();
    } catch (e, stack) {
      debugPrint('Uygulama kapatılamadı: $e\n$stack');
    }
    exit(0);
  }

  Future<void> _refreshTrayMenu() async {
    await trayManager.setContextMenu(Menu(items: _buildMenuItems()));
  }

  List<MenuItem> _buildMenuItems() {
    final items = <MenuItem>[];

    // 1) Gelen eşleşme isteği (varsa en üstte).
    final reconnect = RecentConnectionService.instance.incomingReconnectRequest;
    if (reconnect != null) {
      items.add(MenuItem(
        key: 'reconnect_label',
        label: '${reconnect.fromDeviceName} bağlanmak istiyor',
        disabled: true,
      ));
      items.add(MenuItem(key: 'reconnect_approve', label: '   Onayla'));
      items.add(MenuItem(key: 'reconnect_reject', label: '   Reddet'));
      items.add(MenuItem.separator());
    }

    // 2) Aktif oturumda onay bekleyen gelen dosyalar.
    final controller = ActiveSessionRegistry.instance.activeController;
    final awaiting = controller?.awaitingApprovalFiles ?? const [];
    if (awaiting.isNotEmpty) {
      items.add(MenuItem(
        key: 'files_label',
        label: 'Gelen dosyalar (${awaiting.length})',
        disabled: true,
      ));
      items.add(MenuItem(key: 'files_accept_all', label: '   Tümünü onayla'));
      items.add(MenuItem(key: 'files_reject_all', label: '   Tümünü reddet'));
      for (final file in awaiting) {
        items.add(MenuItem.submenu(
          label: '   ${_shortName(file.name)}',
          submenu: Menu(items: [
            MenuItem(key: 'file_accept:${file.id}', label: 'Onayla'),
            MenuItem(key: 'file_reject:${file.id}', label: 'Reddet'),
          ]),
        ));
      }
      items.add(MenuItem.separator());
    }

    // 3) Cihazlarım — seçince yeniden bağlanma.
    final devices = PairedDevicesService.instance.devices;
    if (devices.isNotEmpty) {
      items.add(MenuItem.submenu(
        label: 'Cihaza bağlan',
        submenu: Menu(
          items: [
            for (final device in devices)
              MenuItem(
                key: 'connect:${device.deviceId}',
                label: device.displayName,
              ),
          ],
        ),
      ));
      items.add(MenuItem.separator());
    }

    items.add(MenuItem(key: 'show', label: 'DirectDrop\'u aç'));
    items.add(MenuItem(key: 'quit', label: 'Çıkış'));
    return items;
  }

  String _shortName(String name) =>
      name.length <= 32 ? name : '${name.substring(0, 29)}…';

  Future<void> _destroyTray() async {
    if (!_trayActive && !_initialized) return;
    try {
      trayManager.removeListener(this);
      await trayManager.destroy();
    } catch (e, stack) {
      debugPrint('Tepsi simgesi kaldırılamadı: $e\n$stack');
    }
    _trayActive = false;
  }

  @override
  void onWindowClose() {
    if (!isSupported || _isQuitting) return;
    unawaited(() async {
      await hideMainWindow();
      await onMainWindowHidden?.call();
    }());
  }

  @override
  void onTrayIconMouseDown() {
    // Sol tık: uygulamayı açmak yerine güncel menüyü göster.
    unawaited(_popUpFreshMenu());
  }

  @override
  void onTrayIconRightMouseDown() {
    unawaited(_popUpFreshMenu());
  }

  Future<void> _popUpFreshMenu() async {
    await _refreshTrayMenu();
    await trayManager.popUpContextMenu();
  }

  @override
  void onTrayMenuItemClick(MenuItem menuItem) {
    final key = menuItem.key;
    if (key == null) return;

    if (key == 'show') {
      if (onShowMainApp != null) {
        unawaited(onShowMainApp!());
      } else {
        unawaited(showMainWindow(force: true));
      }
      return;
    }
    if (key == 'quit') {
      unawaited(quitApp());
      return;
    }
    if (key == 'reconnect_approve') {
      final request = RecentConnectionService.instance.incomingReconnectRequest;
      if (request != null) onApproveReconnect?.call(request);
      return;
    }
    if (key == 'reconnect_reject') {
      final request = RecentConnectionService.instance.incomingReconnectRequest;
      if (request != null) {
        unawaited(
          RecentConnectionService.instance
              .rejectIncomingReconnectRequest(request),
        );
      }
      return;
    }
    if (key == 'files_accept_all') {
      unawaited(
        ActiveSessionRegistry.instance.activeController?.acceptAllIncomingFiles(),
      );
      unawaited(DesktopOverlayService.instance.showTransferHud());
      return;
    }
    if (key == 'files_reject_all') {
      unawaited(
        ActiveSessionRegistry.instance.activeController?.rejectAllIncomingFiles(),
      );
      return;
    }
    if (key.startsWith('file_accept:')) {
      final id = key.substring('file_accept:'.length);
      unawaited(
        ActiveSessionRegistry.instance.activeController?.acceptIncomingFile(id),
      );
      unawaited(DesktopOverlayService.instance.showTransferHud());
      return;
    }
    if (key.startsWith('file_reject:')) {
      final id = key.substring('file_reject:'.length);
      unawaited(
        ActiveSessionRegistry.instance.activeController?.rejectIncomingFile(id),
      );
      return;
    }
    if (key.startsWith('connect:')) {
      final deviceId = key.substring('connect:'.length);
      final devices = PairedDevicesService.instance.devices;
      PairedDevice? match;
      for (final device in devices) {
        if (device.deviceId == deviceId) {
          match = device;
          break;
        }
      }
      if (match != null) onConnectToPeer?.call(match);
      return;
    }
  }
}
