import 'transfer_file.dart';

/// Disk üzerindeki yarım transfer — uygulama yeniden açıldığında sürdürülür.
class TransferCheckpoint {
  TransferCheckpoint({
    required this.fileId,
    required this.peerDeviceId,
    required this.peerDisplayName,
    required this.name,
    required this.size,
    required this.bytesTransferred,
    required this.direction,
    required this.status,
    required this.chunkSize,
    required this.updatedAtMs,
    this.localPath,
    this.sha256,
    this.mimeType,
  });

  final String fileId;
  final String peerDeviceId;
  final String peerDisplayName;
  final String name;
  final int size;
  final int bytesTransferred;
  final TransferDirection direction;
  final TransferStatus status;
  final int chunkSize;
  final int updatedAtMs;
  final String? localPath;
  final String? sha256;
  final String? mimeType;

  Map<String, dynamic> toJson() => {
        'fileId': fileId,
        'peerDeviceId': peerDeviceId,
        'peerDisplayName': peerDisplayName,
        'name': name,
        'size': size,
        'bytesTransferred': bytesTransferred,
        'direction': direction.name,
        'status': status.name,
        'chunkSize': chunkSize,
        'updatedAtMs': updatedAtMs,
        if (localPath != null) 'localPath': localPath,
        if (sha256 != null) 'sha256': sha256,
        if (mimeType != null) 'mimeType': mimeType,
      };

  factory TransferCheckpoint.fromJson(Map<String, dynamic> json) {
    return TransferCheckpoint(
      fileId: json['fileId'] as String,
      peerDeviceId: json['peerDeviceId'] as String,
      peerDisplayName: json['peerDisplayName'] as String? ?? 'Cihaz',
      name: json['name'] as String,
      size: (json['size'] as num).toInt(),
      bytesTransferred: (json['bytesTransferred'] as num?)?.toInt() ?? 0,
      direction: TransferDirection.values.byName(json['direction'] as String),
      status: TransferStatus.values.byName(json['status'] as String),
      chunkSize: (json['chunkSize'] as num?)?.toInt() ?? 65536,
      updatedAtMs: (json['updatedAtMs'] as num?)?.toInt() ?? 0,
      localPath: json['localPath'] as String?,
      sha256: json['sha256'] as String?,
      mimeType: json['mimeType'] as String?,
    );
  }
}

class InterruptedTransferGroup {
  const InterruptedTransferGroup({
    required this.peerDeviceId,
    required this.peerDisplayName,
    required this.checkpoints,
  });

  final String peerDeviceId;
  final String peerDisplayName;
  final List<TransferCheckpoint> checkpoints;

  int get fileCount => checkpoints.length;

  int get totalBytes =>
      checkpoints.fold<int>(0, (sum, cp) => sum + cp.size);

  int get transferredBytes =>
      checkpoints.fold<int>(0, (sum, cp) => sum + cp.bytesTransferred);
}
