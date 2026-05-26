import 'transfer_file.dart';

class TransferHistoryRecord {
  const TransferHistoryRecord({
    required this.id,
    required this.peerDeviceId,
    required this.peerName,
    required this.fileName,
    required this.fileSize,
    required this.direction,
    required this.status,
    required this.completedAt,
    this.localPath,
    this.errorMessage,
  });

  final String id;
  final String peerDeviceId;
  final String peerName;
  final String fileName;
  final int fileSize;
  final TransferDirection direction;
  final TransferStatus status;
  final DateTime completedAt;
  final String? localPath;
  final String? errorMessage;

  Map<String, dynamic> toJson() => {
        'id': id,
        'peerDeviceId': peerDeviceId,
        'peerName': peerName,
        'fileName': fileName,
        'fileSize': fileSize,
        'direction': direction.name,
        'status': status.name,
        'completedAt': completedAt.toIso8601String(),
        if (localPath != null) 'localPath': localPath,
        if (errorMessage != null) 'errorMessage': errorMessage,
      };

  factory TransferHistoryRecord.fromJson(Map<String, dynamic> json) {
    return TransferHistoryRecord(
      id: json['id'] as String,
      peerDeviceId: json['peerDeviceId'] as String,
      peerName: json['peerName'] as String? ?? 'Cihaz',
      fileName: json['fileName'] as String,
      fileSize: (json['fileSize'] as num).toInt(),
      direction: TransferDirection.values.firstWhere(
        (d) => d.name == json['direction'],
        orElse: () => TransferDirection.receiving,
      ),
      status: TransferStatus.values.firstWhere(
        (s) => s.name == json['status'],
        orElse: () => TransferStatus.completed,
      ),
      completedAt: DateTime.tryParse(json['completedAt'] as String? ?? '') ??
          DateTime.now(),
      localPath: json['localPath'] as String?,
      errorMessage: json['errorMessage'] as String?,
    );
  }

  TransferFileItem toDisplayItem() {
    return TransferFileItem(
      id: id,
      name: fileName,
      size: fileSize,
      direction: direction,
      localPath: localPath,
      bytesTransferred: status == TransferStatus.completed ? fileSize : 0,
      status: status,
      errorMessage: errorMessage,
    );
  }
}
