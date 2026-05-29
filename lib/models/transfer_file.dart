enum TransferDirection { sending, receiving }

enum TransferStatus {
  pending,
  awaitingApproval,
  inProgress,
  paused,
  verifying,
  completed,
  failed,
  cancelled,
}

class TransferFileItem {
  TransferFileItem({
    required this.id,
    required this.name,
    required this.size,
    required this.direction,
    this.mimeType,
    this.localPath,
    this.sha256,
    this.bytesTransferred = 0,
    this.status = TransferStatus.pending,
    this.errorMessage,
  });

  final String id;
  final String name;
  final int size;
  final TransferDirection direction;
  final String? mimeType;
  String? localPath;
  final String? sha256;
  int bytesTransferred;
  TransferStatus status;
  String? errorMessage;

  double get progress => size == 0 ? 0 : bytesTransferred / size;

  TransferFileItem copyWith({
    int? bytesTransferred,
    TransferStatus? status,
    String? localPath,
    String? sha256,
    String? errorMessage,
  }) {
    return TransferFileItem(
      id: id,
      name: name,
      size: size,
      direction: direction,
      mimeType: mimeType,
      localPath: localPath ?? this.localPath,
      sha256: sha256 ?? this.sha256,
      bytesTransferred: bytesTransferred ?? this.bytesTransferred,
      status: status ?? this.status,
      errorMessage: errorMessage ?? this.errorMessage,
    );
  }
}
