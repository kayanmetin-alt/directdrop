import 'dart:io';

import 'package:flutter/material.dart';

import '../services/desktop_overlay_service.dart';

/// Windows köşe panelinin Flutter arayüzü. [DesktopOverlayService.windowPanelData]
/// değeri null değilken, [WindowsOverlayWindow] tarafından küçültülmüş pencerede
/// tam ekran kaplar. macOS native panellerinin görsel/işlevsel karşılığıdır.
class WindowsOverlayHost extends StatelessWidget {
  const WindowsOverlayHost({super.key});

  @override
  Widget build(BuildContext context) {
    if (!Platform.isWindows) return const SizedBox.shrink();

    return ValueListenableBuilder<Map<String, dynamic>?>(
      valueListenable: DesktopOverlayService.instance.windowPanelData,
      builder: (context, data, _) {
        if (data == null) return const SizedBox.shrink();
        return _OverlayPanel(data: data);
      },
    );
  }
}

class _OverlayPanel extends StatelessWidget {
  const _OverlayPanel({required this.data});

  final Map<String, dynamic> data;

  static const _bg = Color(0xFF1C1C1E);
  static const _card = Color(0xFF2A2A2E);
  static const _border = Color(0x22FFFFFF);
  static const _accent = Color(0xFF2563EB);

  DesktopOverlayService get _service => DesktopOverlayService.instance;

  @override
  Widget build(BuildContext context) {
    final reconnect = (data['reconnect'] as Map?)?.cast<String, dynamic>();
    final files = (data['files'] as Map?)?.cast<String, dynamic>();

    return Material(
      color: _bg,
      child: Stack(
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(12, 12, 12, 12),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              mainAxisSize: MainAxisSize.min,
              children: [
                if (reconnect != null) _buildReconnect(reconnect),
                if (reconnect != null && files != null)
                  const SizedBox(height: 12),
                if (files != null) Flexible(child: _buildFiles(files)),
              ],
            ),
          ),
          Positioned(
            top: 6,
            right: 6,
            child: _CloseButton(
              onTap: () => _service.handlePanelAction('panel_dismiss', const {}),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildReconnect(Map<String, dynamic> r) {
    final phase = r['phase'] as String? ?? 'prompt';
    final title = r['title'] as String? ?? '';
    final subtitle = r['subtitle'] as String? ?? '';
    final isPrompt = phase == 'prompt';
    final isConnecting = phase == 'connecting';
    final isConnected = phase == 'connected';
    final isDisconnected = phase == 'disconnected';

    final IconData glyph;
    final Color tint;
    if (isDisconnected) {
      glyph = Icons.wifi_off_rounded;
      tint = const Color(0xFFE5484D);
    } else if (isConnected) {
      glyph = Icons.check_circle_rounded;
      tint = const Color(0xFF30A46C);
    } else {
      glyph = Icons.swap_vert_circle_rounded;
      tint = _accent;
    }

    return Container(
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: _card,
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: _border),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        mainAxisSize: MainAxisSize.min,
        children: [
          Row(
            children: [
              Container(
                width: 40,
                height: 40,
                decoration: BoxDecoration(
                  color: tint.withValues(alpha: 0.16),
                  shape: BoxShape.circle,
                ),
                child: Icon(glyph, color: tint, size: 22),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Text(
                      title,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(
                        color: Colors.white,
                        fontSize: 14,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                    const SizedBox(height: 2),
                    Text(
                      subtitle,
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(
                        color: Color(0xFFB0B0B6),
                        fontSize: 12,
                      ),
                    ),
                  ],
                ),
              ),
              if (isConnecting)
                const Padding(
                  padding: EdgeInsets.only(left: 8),
                  child: SizedBox(
                    width: 18,
                    height: 18,
                    child: CircularProgressIndicator(
                      strokeWidth: 2,
                      color: _accent,
                    ),
                  ),
                ),
            ],
          ),
          if (isPrompt) ...[
            const SizedBox(height: 12),
            Row(
              children: [
                Expanded(
                  child: _PanelButton(
                    label: 'Reddet',
                    onTap: () => _service.handlePanelAction(
                      'reconnect_reject',
                      _reconnectArgs(r),
                    ),
                  ),
                ),
                const SizedBox(width: 10),
                Expanded(
                  child: _PanelButton(
                    label: 'Onayla',
                    prominent: true,
                    onTap: () => _service.handlePanelAction(
                      'reconnect_approve',
                      _reconnectArgs(r),
                    ),
                  ),
                ),
              ],
            ),
          ],
        ],
      ),
    );
  }

  Map<String, dynamic> _reconnectArgs(Map<String, dynamic> r) => {
        'fromDeviceId': r['fromDeviceId'] ?? '',
        'fromDeviceName': r['fromDeviceName'] ?? 'Cihaz',
        'clientCreatedAt': r['clientCreatedAt'] ?? 0,
      };

  Widget _buildFiles(Map<String, dynamic> f) {
    final title = f['title'] as String? ?? '';
    final subtitle = f['subtitle'] as String? ?? '';
    final showBulk = f['showBulkActions'] == true;
    final showOpen = f['showOpenAction'] == true;
    final items = ((f['items'] as List?) ?? const [])
        .map((e) => (e as Map).cast<String, dynamic>())
        .toList();

    return Container(
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: _card,
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: _border),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        mainAxisSize: MainAxisSize.min,
        children: [
          Text(
            title,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: const TextStyle(
              color: Colors.white,
              fontSize: 14,
              fontWeight: FontWeight.w600,
            ),
          ),
          if (subtitle.isNotEmpty) ...[
            const SizedBox(height: 2),
            Text(
              subtitle,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: const TextStyle(color: Color(0xFFB0B0B6), fontSize: 12),
            ),
          ],
          const SizedBox(height: 10),
          Flexible(
            child: ListView.separated(
              shrinkWrap: true,
              padding: EdgeInsets.zero,
              itemCount: items.length,
              separatorBuilder: (_, __) => const SizedBox(height: 6),
              itemBuilder: (_, i) => _FileRow(
                item: items[i],
                service: _service,
              ),
            ),
          ),
          if (showBulk) ...[
            const SizedBox(height: 10),
            Row(
              children: [
                Expanded(
                  child: _PanelButton(
                    label: 'Tümünü reddet',
                    onTap: () =>
                        _service.handlePanelAction('files_reject_all', const {}),
                  ),
                ),
                const SizedBox(width: 10),
                Expanded(
                  child: _PanelButton(
                    label: 'Tümünü onayla',
                    prominent: true,
                    onTap: () =>
                        _service.handlePanelAction('files_accept_all', const {}),
                  ),
                ),
              ],
            ),
          ],
          if (showOpen) ...[
            const SizedBox(height: 10),
            _PanelButton(
              label: 'Dosyaları aç',
              prominent: true,
              onTap: () => _service.handlePanelAction('files_open', const {}),
            ),
          ],
        ],
      ),
    );
  }
}

class _FileRow extends StatelessWidget {
  const _FileRow({required this.item, required this.service});

  final Map<String, dynamic> item;
  final DesktopOverlayService service;

  @override
  Widget build(BuildContext context) {
    final id = item['id'] as String? ?? '';
    final name = item['name'] as String? ?? '';
    final phase = item['phase'] as String? ?? 'pending';
    final progress = (item['progress'] as num?)?.toDouble() ?? 0;
    final status = item['status'] as String? ?? '';
    final isPending = phase == 'pending';
    final isCompleted = phase == 'completed';

    return Row(
      children: [
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(
                name,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: const TextStyle(color: Colors.white, fontSize: 13),
              ),
              if (!isPending) ...[
                const SizedBox(height: 4),
                Row(
                  children: [
                    Expanded(
                      child: ClipRRect(
                        borderRadius: BorderRadius.circular(3),
                        child: LinearProgressIndicator(
                          value: isCompleted ? 1 : progress.clamp(0.0, 1.0),
                          minHeight: 4,
                          backgroundColor: const Color(0x33FFFFFF),
                          valueColor: AlwaysStoppedAnimation<Color>(
                            isCompleted
                                ? const Color(0xFF30A46C)
                                : const Color(0xFF2563EB),
                          ),
                        ),
                      ),
                    ),
                    const SizedBox(width: 8),
                    Text(
                      status,
                      style: const TextStyle(
                        color: Color(0xFF9A9AA0),
                        fontSize: 11,
                      ),
                    ),
                  ],
                ),
              ],
            ],
          ),
        ),
        if (isPending) ...[
          const SizedBox(width: 8),
          _TextGlyphButton(
            symbol: '✕',
            color: const Color(0xFFE5484D),
            onTap: () => service.handlePanelAction('file_reject', {'fileId': id}),
          ),
          const SizedBox(width: 4),
          _TextGlyphButton(
            symbol: '✓',
            color: const Color(0xFF30A46C),
            onTap: () => service.handlePanelAction('file_accept', {'fileId': id}),
          ),
        ],
      ],
    );
  }
}

class _PanelButton extends StatelessWidget {
  const _PanelButton({
    required this.label,
    required this.onTap,
    this.prominent = false,
  });

  final String label;
  final VoidCallback onTap;
  final bool prominent;

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      height: 34,
      child: TextButton(
        onPressed: onTap,
        style: TextButton.styleFrom(
          backgroundColor:
              prominent ? const Color(0xFF2563EB) : const Color(0x1FFFFFFF),
          foregroundColor: Colors.white,
          padding: EdgeInsets.zero,
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(8),
          ),
        ),
        child: Text(
          label,
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
          style: TextStyle(
            fontSize: 12,
            fontWeight: prominent ? FontWeight.w600 : FontWeight.w500,
          ),
        ),
      ),
    );
  }
}

class _TextGlyphButton extends StatelessWidget {
  const _TextGlyphButton({
    required this.symbol,
    required this.color,
    required this.onTap,
  });

  final String symbol;
  final Color color;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(8),
      child: Container(
        width: 30,
        height: 30,
        alignment: Alignment.center,
        decoration: BoxDecoration(
          color: color.withValues(alpha: 0.14),
          borderRadius: BorderRadius.circular(8),
        ),
        child: Text(
          symbol,
          style: TextStyle(
            color: color,
            fontSize: 15,
            fontWeight: FontWeight.w700,
          ),
        ),
      ),
    );
  }
}

class _CloseButton extends StatelessWidget {
  const _CloseButton({required this.onTap});

  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(14),
      child: Container(
        width: 24,
        height: 24,
        alignment: Alignment.center,
        decoration: const BoxDecoration(
          color: Color(0x22FFFFFF),
          shape: BoxShape.circle,
        ),
        child: const Icon(Icons.close_rounded, size: 15, color: Colors.white),
      ),
    );
  }
}
