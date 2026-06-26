/// QR veya elle girilen metinden kod ve tür (cihaz daveti / geçici oda) çıkarır.
class InviteCodeParser {
  InviteCodeParser._();

  static final _codePattern = RegExp(r'^[A-Z0-9]{6,8}$');
  static final _embeddedPattern = RegExp(r'[A-Z0-9]{6,8}');

  /// `directdrop://device/ABC123`, `directdrop://join/ABC123` veya düz kod.
  static InviteCodePayload parse(String raw) {
    final trimmed = raw.trim();
    if (trimmed.isEmpty) {
      return const InviteCodePayload(code: '', kind: InviteCodeKind.unknown);
    }

    final uri = Uri.tryParse(trimmed);
    if (uri != null) {
      final host = uri.host.toLowerCase();
      final path = uri.path.toLowerCase();

      if (host == 'device' || path.startsWith('/device/') || path.startsWith('/d/')) {
        final code = _codeFromUri(uri, preferredSegment: 'device');
        if (code != null) {
          return InviteCodePayload(code: code, kind: InviteCodeKind.device);
        }
      }
      if (host == 'join' ||
          host == 'room' ||
          path.startsWith('/join/') ||
          path.startsWith('/j/') ||
          path.startsWith('/room/')) {
        final code = _codeFromUri(uri, preferredSegment: 'join');
        if (code != null) {
          return InviteCodePayload(code: code, kind: InviteCodeKind.room);
        }
      }
    }

    final code = _extractPlainCode(trimmed);
    if (!isValid(code)) {
      return InviteCodePayload(code: code, kind: InviteCodeKind.unknown);
    }
    return InviteCodePayload(code: code, kind: InviteCodeKind.auto);
  }

  static String _extractPlainCode(String raw) {
    var text = raw.trim().toUpperCase();
    if (text.isEmpty) return text;
    if (_codePattern.hasMatch(text)) return text;

    final uri = Uri.tryParse(raw.trim());
    if (uri != null) {
      for (final segment in uri.pathSegments.reversed) {
        final candidate = segment.trim().toUpperCase();
        if (_codePattern.hasMatch(candidate)) return candidate;
      }
      for (final value in uri.queryParameters.values) {
        final candidate = value.trim().toUpperCase();
        if (_codePattern.hasMatch(candidate)) return candidate;
      }
    }

    final match = _embeddedPattern.firstMatch(text);
    return match?.group(0) ?? text;
  }

  static String? _codeFromUri(Uri uri, {required String preferredSegment}) {
    final segments = uri.pathSegments;
    if (segments.length >= 2 &&
        segments[0].toLowerCase() == preferredSegment &&
        isValid(segments[1].toUpperCase())) {
      return segments[1].toUpperCase();
    }
    if (segments.isNotEmpty) {
      final last = segments.last.toUpperCase();
      if (isValid(last)) return last;
    }
    for (final value in uri.queryParameters.values) {
      final candidate = value.trim().toUpperCase();
      if (isValid(candidate)) return candidate;
    }
    return null;
  }

  static String normalize(String raw) => parse(raw).code;

  static bool isValid(String code) => _codePattern.hasMatch(code);
}

enum InviteCodeKind {
  /// Cihaza özel kalıcı davet QR'ı.
  device,

  /// Transfer Başlat ekranındaki geçici oda QR'ı.
  room,

  /// Düz kod — önce cihaz daveti, sonra açık oda denenir.
  auto,

  unknown,
}

class InviteCodePayload {
  const InviteCodePayload({
    required this.code,
    required this.kind,
  });

  final String code;
  final InviteCodeKind kind;
}
