import 'package:firebase_core/firebase_core.dart';

/// Kullanıcıya gösterilecek kısa hata metni (native stack trace gizlenir).
String userFacingMessage(Object error) {
  if (error is StateError) {
    final msg = error.message;
    if (msg.isNotEmpty) return msg;
  }

  if (error is FirebaseException) {
    switch (error.code) {
      case 'permission-denied':
        return 'Sunucu izni reddedildi. Her iki cihazda uygulamayı güncelleyin. '
            'Windows\'ta Transfer Başlat ile yeni oda açıp kodu tekrar deneyin.';
      case 'network-error':
      case 'unavailable':
        return 'İnternet veya Firebase bağlantısı yok. Ağı kontrol edip tekrar deneyin.';
      case 'unknown':
        return 'Sunucuya bağlanılamadı. Her iki cihazda uygulama açık olsun; '
            'olmazsa QR ile yeniden eşleşin.';
      default:
        break;
    }
  }

  final text = error.toString();
  if (text.contains('firebase_database') ||
      text.contains('FirebaseException') ||
      text.contains('Stacktrace:')) {
    return 'Sunucuya bağlanılamadı. Karşı cihazda uygulamayı açıp listeden '
        'bağlanmayı deneyin; olmazsa QR kullanın.';
  }

  if (text.length > 280) {
    return '${text.substring(0, 277)}…';
  }
  return text;
}
