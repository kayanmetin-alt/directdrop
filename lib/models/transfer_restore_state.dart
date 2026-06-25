import 'transfer_file.dart';

/// WebRTC yeniden bağlanırken korunan dosya transferi durumu.
class TransferRestoreState {
  TransferRestoreState({
    required this.items,
    required this.receiveSnapshots,
    required this.outboundJobIds,
    required this.pausedFileIds,
    required this.cancelledFileIds,
    required this.pendingIncomingChunkSizes,
  });

  final List<TransferFileItem> items;
  final List<ReceiveContextSnapshot> receiveSnapshots;
  final List<String> outboundJobIds;
  final Set<String> pausedFileIds;
  final Set<String> cancelledFileIds;
  final Map<String, int> pendingIncomingChunkSizes;
}

class ReceiveContextSnapshot {
  ReceiveContextSnapshot({
    required this.item,
    required this.chunkSize,
  });

  final TransferFileItem item;
  final int chunkSize;
}
