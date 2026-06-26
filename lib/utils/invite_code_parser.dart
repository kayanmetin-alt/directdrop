/// QR veya elle girilen metinden kalıcı cihaz davet kodunu çıkarır.
class InviteCodeParser {
  InviteCodeParser._();

  static final _codePattern = RegExp(r'^[A-Z0-9]{6,8}$');
  static final _embeddedPattern = RegExp(r'[A-Z0-9]{6,8}');

  static String normalize(String raw) {
    var text = raw.trim().toUpperCase();
    if (text.isEmpty) return text;

    if (_codePattern.hasMatch(text)) return text;

    final uri = Uri.tryParse(text);
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

  static bool isValid(String code) => _codePattern.hasMatch(code);
}
