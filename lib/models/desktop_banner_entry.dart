import '../models/reconnect_request.dart';
import '../models/transfer_file.dart';

enum DesktopBannerKind { reconnect, incomingFiles }

class DesktopBannerEntry {
  DesktopBannerEntry({
    required this.id,
    required this.kind,
    required this.title,
    required this.subtitle,
    this.reconnect,
    this.files = const [],
    this.peerName,
  });

  final String id;
  final DesktopBannerKind kind;
  final String title;
  final String subtitle;
  final ReconnectRequest? reconnect;
  final List<TransferFileItem> files;
  final String? peerName;
}
