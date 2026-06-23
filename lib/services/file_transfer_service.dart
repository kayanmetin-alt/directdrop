import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter_webrtc/flutter_webrtc.dart';
import 'package:path/path.dart' as p;
import 'package:uuid/uuid.dart';

import '../models/transfer_file.dart';
import '../utils/file_hasher.dart';
import 'download_directory_service.dart';
import 'webrtc_service.dart';

class TransferRejectedException implements Exception {
  TransferRejectedException([this.message = 'Karşı taraf dosyayı reddetti']);

  final String message;

  @override
  String toString() => message;
}

class TransferCancelledException implements Exception {
  TransferCancelledException([this.message = 'Transfer iptal edildi']);

  final String message;

  @override
  String toString() => message;
}

class FileTransferService {
  FileTransferService({required WebRtcService webRtc}) : _webRtc = webRtc {
    _subscription = _webRtc.incomingData.listen((raw) {
      _incomingChain = _incomingChain.then((_) async {
        try {
          await _processIncoming(raw);
        } catch (e, stack) {
          debugPrint('Gelen mesaj işlenemedi: $e\n$stack');
        }
      });
    });
  }

  static const chunkSize = 65536; // 64 KB
  static const _uuid = Uuid();

  final WebRtcService _webRtc;
  late final StreamSubscription<dynamic> _subscription;

  final _transfersController =
      StreamController<List<TransferFileItem>>.broadcast();
  Stream<List<TransferFileItem>> get transfers => _transfersController.stream;

  final List<TransferFileItem> _items = [];
  final Map<String, _ReceiveContext> _receiveContexts = {};
  final Map<String, _PendingIncomingFile> _pendingIncoming = {};
  final Map<String, Completer<void>> _pendingAcks = {};
  final Map<String, Completer<void>> _pendingReady = {};
  final Map<String, Completer<void>> _pendingPongs = {};
  final Set<String> _pausedFileIds = {};
  final Set<String> _cancelledFileIds = {};
  Future<void> _incomingChain = Future.value();

  List<TransferFileItem> get items => List.unmodifiable(_items);

  List<TransferFileItem> get awaitingApprovalItems => _items
      .where(
        (item) =>
            item.direction == TransferDirection.receiving &&
            item.status == TransferStatus.awaitingApproval,
      )
      .toList();

  void _emit() => _transfersController.add(List.unmodifiable(_items));

  Future<void> ensurePeerReady() async {
    for (var i = 0; i < 50; i++) {
      if (_webRtc.isDataChannelOpen) break;
      await Future<void>.delayed(const Duration(milliseconds: 100));
    }

    if (!_webRtc.isDataChannelOpen) {
      throw StateError('Veri kanalı hazır değil.');
    }

    final pingId = _uuid.v4();
    final pongCompleter = Completer<void>();
    _pendingPongs[pingId] = pongCompleter;

    try {
      await _sendControl({'type': 'ping', 'id': pingId});
      await pongCompleter.future.timeout(
        const Duration(seconds: 5),
        onTimeout: () => throw TimeoutException('Karşı cihaz yanıt vermiyor'),
      );
    } finally {
      _pendingPongs.remove(pingId);
    }
  }

  Future<void> sendFiles(
    List<String> filePaths, {
    void Function(int fileIndex, int fileCount, double fileFraction, String fileName)?
        onHashProgress,
  }) async {
    if (filePaths.isEmpty) return;

    final jobs = <_OutboundFileJob>[];
    for (var i = 0; i < filePaths.length; i++) {
      final path = filePaths[i];
      jobs.add(
        await _prepareOutboundJob(
          path,
          onHashProgress: onHashProgress == null
              ? null
              : (fraction) => onHashProgress(i, filePaths.length, fraction,
                    p.basename(path)),
        ),
      );
    }

    for (final job in jobs) {
      while (!_webRtc.isDataChannelOpen) {
        await Future<void>.delayed(const Duration(milliseconds: 100));
      }

      final readyCompleter = Completer<void>();
      _pendingReady[job.item.id] = readyCompleter;
      job.readyCompleter = readyCompleter;

      job.item.status = TransferStatus.awaitingApproval;
      _emit();

      await _sendControl({
        'type': 'file_start',
        'id': job.item.id,
        'name': job.item.name,
        'size': job.item.size,
        'sha256': job.item.sha256,
        'chunkSize': chunkSize,
      });
    }

    for (final job in jobs) {
      await _executeOutboundTransfer(job);
    }
  }

  Future<void> acceptAllIncoming() async {
    final ids = _pendingIncoming.keys.toList(growable: false);
    for (final id in ids) {
      await acceptIncoming(id);
    }
  }

  Future<void> rejectAllIncoming() async {
    final ids = _pendingIncoming.keys.toList(growable: false);
    for (final id in ids) {
      await rejectIncoming(id);
    }
  }

  Future<void> acceptIncoming(String fileId) async {
    final pending = _pendingIncoming.remove(fileId);
    if (pending == null) return;

    final item = pending.item;
    item.status = TransferStatus.inProgress;
    _emit();

    await _sendControl({'type': 'file_start_ack', 'fileId': fileId});
    await _beginReceiveFile(pending);
  }

  Future<void> rejectIncoming(String fileId) async {
    final pending = _pendingIncoming.remove(fileId);
    if (pending == null) return;

    pending.item.status = TransferStatus.cancelled;
    pending.item.errorMessage = 'Reddedildi';
    _emit();

    await _sendControl({'type': 'file_start_reject', 'fileId': fileId});
  }

  Future<void> pauseTransfer(String fileId) async {
    final item = _itemById(fileId);
    if (item == null || item.status != TransferStatus.inProgress) return;

    _pausedFileIds.add(fileId);
    item.status = TransferStatus.paused;
    _emit();
    await _sendControl({'type': 'file_pause', 'fileId': fileId});
  }

  Future<void> resumeTransfer(String fileId) async {
    final item = _itemById(fileId);
    if (item == null || item.status != TransferStatus.paused) return;

    _pausedFileIds.remove(fileId);
    item.status = TransferStatus.inProgress;
    _emit();
    await _sendControl({'type': 'file_resume', 'fileId': fileId});
  }

  Future<void> cancelTransfer(String fileId) async {
    final item = _itemById(fileId);
    if (item == null || !_isActiveTransfer(item)) return;

    _cancelledFileIds.add(fileId);
    _pausedFileIds.remove(fileId);
    await _abortTransfer(fileId, notifyPeer: true, message: 'İptal edildi');
  }

  TransferFileItem? _itemById(String fileId) {
    for (final item in _items) {
      if (item.id == fileId) return item;
    }
    return null;
  }

  bool _isActiveTransfer(TransferFileItem item) {
    return item.status == TransferStatus.inProgress ||
        item.status == TransferStatus.paused;
  }

  Future<void> _waitWhilePausedOrCancelled(String fileId) async {
    while (_pausedFileIds.contains(fileId)) {
      if (_cancelledFileIds.contains(fileId)) {
        throw TransferCancelledException();
      }
      await Future<void>.delayed(const Duration(milliseconds: 150));
    }
    if (_cancelledFileIds.contains(fileId)) {
      throw TransferCancelledException();
    }
  }

  Future<void> _abortTransfer(
    String fileId, {
    required bool notifyPeer,
    required String message,
  }) async {
    _pendingIncoming.remove(fileId);

    final context = _receiveContexts.remove(fileId);
    if (context != null) {
      try {
        await context.raf.close();
      } catch (_) {}
      final path = context.item.localPath;
      if (path != null) {
        try {
          await File(path).delete();
        } catch (_) {}
      }
    }

    _clearPendingOperationsForFile(fileId);

    if (notifyPeer) {
      try {
        await _sendControl({'type': 'file_cancel', 'fileId': fileId});
      } catch (_) {}
    }

    final item = _itemById(fileId);
    if (item != null && _isActiveTransfer(item)) {
      item.status = TransferStatus.cancelled;
      item.errorMessage = message;
      _emit();
    }

    _pausedFileIds.remove(fileId);
  }

  void _clearPendingOperationsForFile(String fileId) {
    _pendingReady.remove(fileId)?.completeError(TransferCancelledException());
    final ackKeys = _pendingAcks.keys
        .where((key) => key.startsWith('$fileId:'))
        .toList(growable: false);
    for (final key in ackKeys) {
      _pendingAcks.remove(key)?.completeError(TransferCancelledException());
    }
  }

  Future<_OutboundFileJob> _prepareOutboundJob(
    String filePath, {
    void Function(double fraction)? onHashProgress,
  }) async {
    final file = File(filePath);
    if (!await file.exists()) {
      throw StateError('Dosya bulunamadı: $filePath');
    }

    final stat = await file.stat();
    final fileId = _uuid.v4();
    final name = p.basename(filePath);
    final sha256 = await FileHasher.sha256File(
      filePath,
      onProgress: onHashProgress,
    );

    final item = TransferFileItem(
      id: fileId,
      name: name,
      size: stat.size,
      direction: TransferDirection.sending,
      localPath: filePath,
      sha256: sha256,
      status: TransferStatus.pending,
    );
    _items.add(item);
    _emit();

    return _OutboundFileJob(
      file: file,
      item: item,
      size: stat.size,
    );
  }

  Future<void> _executeOutboundTransfer(_OutboundFileJob job) async {
    final fileId = job.item.id;
    final item = job.item;
    final file = job.file;
    final statSize = job.size;
    final readyCompleter = job.readyCompleter;

    if (readyCompleter == null) {
      throw StateError('Gönderim hazırlığı eksik: $fileId');
    }

    try {
      await readyCompleter.future.timeout(
        const Duration(seconds: 120),
        onTimeout: () => throw TimeoutException(
          'Karşı cihaz dosyayı kabul etmedi. Her iki cihazda uygulama açık mı kontrol edin.',
        ),
      );

      item.status = TransferStatus.inProgress;
      _emit();

      final raf = await file.open(mode: FileMode.read);
      try {
        var offset = 0;
        var chunkIndex = 0;
        while (offset < statSize) {
          await _waitWhilePausedOrCancelled(fileId);

          final remaining = statSize - offset;
          final readSize = remaining < chunkSize ? remaining : chunkSize;
          final buffer = Uint8List(readSize);
          await raf.readInto(buffer);

          final packet = _buildChunkPacket(fileId, chunkIndex, buffer);
          await _webRtc.send(RTCDataChannelMessage.fromBinary(packet));

          final ackKey = '$fileId:$chunkIndex';
          final ackCompleter = Completer<void>();
          _pendingAcks[ackKey] = ackCompleter;
          await ackCompleter.future.timeout(
            const Duration(seconds: 30),
            onTimeout: () => throw TimeoutException('Parça onayı zaman aşımı'),
          );

          offset += readSize;
          chunkIndex++;
          item.bytesTransferred = offset;
          _emit();
        }
      } finally {
        await raf.close();
      }

      await _sendControl({'type': 'file_end', 'id': fileId});

      item.status = TransferStatus.completed;
    } on TransferRejectedException catch (e) {
      item.status = TransferStatus.cancelled;
      item.errorMessage = e.message;
    } on TransferCancelledException catch (e) {
      if (item.status != TransferStatus.cancelled) {
        item.status = TransferStatus.cancelled;
        item.errorMessage = e.message;
      }
    } catch (e) {
      item.status = TransferStatus.failed;
      item.errorMessage = e.toString();
      rethrow;
    } finally {
      _pendingReady.remove(fileId);
      _pausedFileIds.remove(fileId);
      _cancelledFileIds.remove(fileId);
      _emit();
    }
  }

  Uint8List _buildChunkPacket(String fileId, int chunkIndex, Uint8List data) {
    final idBytes = utf8.encode(fileId);
    final packet = Uint8List(2 + idBytes.length + 4 + data.length);
    final view = ByteData.view(packet.buffer);

    view.setUint16(0, idBytes.length);
    packet.setRange(2, 2 + idBytes.length, idBytes);
    view.setUint32(2 + idBytes.length, chunkIndex);
    packet.setRange(2 + idBytes.length + 4, packet.length, data);
    return packet;
  }

  Future<void> _sendControl(Map<String, dynamic> payload) async {
    await _webRtc.send(RTCDataChannelMessage(jsonEncode(payload)));
  }

  Future<void> _processIncoming(dynamic raw) async {
    if (raw is! RTCDataChannelMessage) return;

    if (raw.isBinary) {
      await _handleBinaryChunk(raw.binary);
      return;
    }

    final text = raw.text;
    if (text.isEmpty) return;

    try {
      final payload = jsonDecode(text) as Map<String, dynamic>;
      await _handleControl(payload);
    } catch (e) {
      debugPrint('Kontrol mesajı parse hatası: $e');
    }
  }

  Future<void> _handleControl(Map<String, dynamic> payload) async {
    switch (payload['type']) {
      case 'ping':
        await _sendControl({'type': 'pong', 'id': payload['id']});
      case 'pong':
        final pingId = payload['id'] as String?;
        if (pingId != null) {
          _pendingPongs.remove(pingId)?.complete();
        }
      case 'file_start':
        await _queueIncomingFile(payload);
      case 'file_start_ack':
        final readyFileId = payload['fileId'] as String;
        _pendingReady.remove(readyFileId)?.complete();
      case 'file_start_reject':
        final rejectedFileId = payload['fileId'] as String;
        final completer = _pendingReady.remove(rejectedFileId);
        if (completer != null && !completer.isCompleted) {
          completer.completeError(TransferRejectedException());
        }
      case 'file_pause':
        final pauseFileId = payload['fileId'] as String;
        _pausedFileIds.add(pauseFileId);
        final pausedItem = _itemById(pauseFileId);
        if (pausedItem != null &&
            pausedItem.status == TransferStatus.inProgress) {
          pausedItem.status = TransferStatus.paused;
          _emit();
        }
      case 'file_resume':
        final resumeFileId = payload['fileId'] as String;
        _pausedFileIds.remove(resumeFileId);
        final resumedItem = _itemById(resumeFileId);
        if (resumedItem != null && resumedItem.status == TransferStatus.paused) {
          resumedItem.status = TransferStatus.inProgress;
          _emit();
        }
      case 'file_cancel':
        final cancelFileId = payload['fileId'] as String;
        _cancelledFileIds.add(cancelFileId);
        _pausedFileIds.remove(cancelFileId);
        await _abortTransfer(
          cancelFileId,
          notifyPeer: false,
          message: 'Karşı taraf iptal etti',
        );
      case 'file_end':
        await _finishReceive(payload['id'] as String);
      case 'chunk_ack':
        final fileId = payload['fileId'] as String;
        final chunkIndex = (payload['chunkIndex'] as num).toInt();
        _pendingAcks.remove('$fileId:$chunkIndex')?.complete();
      default:
        break;
    }
  }

  Future<void> _queueIncomingFile(Map<String, dynamic> payload) async {
    final fileId = payload['id'] as String;
    final name = payload['name'] as String;
    final size = payload['size'] as int;
    final sha256 = payload['sha256'] as String;

    final item = TransferFileItem(
      id: fileId,
      name: name,
      size: size,
      direction: TransferDirection.receiving,
      sha256: sha256,
      status: TransferStatus.awaitingApproval,
    );

    _pendingIncoming[fileId] = _PendingIncomingFile(
      item: item,
      chunkSize: payload['chunkSize'] as int? ?? chunkSize,
    );

    _items.add(item);
    _emit();
  }

  Future<void> _beginReceiveFile(_PendingIncomingFile pending) async {
    final fileId = pending.item.id;
    final name = pending.item.name;

    final downloadsDir =
        await DownloadDirectoryService.instance.ensureDownloadsDirectory();

    final safeName = _safeFileName(name);
    final localPath = p.join(
      downloadsDir.path,
      '${DateTime.now().millisecondsSinceEpoch}_$safeName',
    );
    final file = File(localPath);
    final raf = await file.open(mode: FileMode.write);

    pending.item.localPath = localPath;
    _receiveContexts[fileId] = _ReceiveContext(
      item: pending.item,
      raf: raf,
      chunkSize: pending.chunkSize,
    );
    _emit();
  }

  Future<void> _handleBinaryChunk(Uint8List packet) async {
    if (packet.length < 6) return;

    final view =
        ByteData.view(packet.buffer, packet.offsetInBytes, packet.length);
    final idLength = view.getUint16(0);
    if (packet.length < 2 + idLength + 4) return;

    final fileId = utf8.decode(packet.sublist(2, 2 + idLength));
    final chunkIndex = view.getUint32(2 + idLength);
    final data = packet.sublist(2 + idLength + 4);

    final context = _receiveContexts[fileId];
    if (context == null) return;

    final offset = chunkIndex * context.chunkSize;
    await context.raf.setPosition(offset);
    await context.raf.writeFrom(data);

    context.item.bytesTransferred =
        (offset + data.length).clamp(0, context.item.size);
    _emit();

    await _sendControl({
      'type': 'chunk_ack',
      'fileId': fileId,
      'chunkIndex': chunkIndex,
    });
  }

  Future<void> _finishReceive(String fileId) async {
    final context = _receiveContexts.remove(fileId);
    if (context == null) return;

    await context.raf.close();
    context.item.status = TransferStatus.verifying;
    _emit();

    try {
      final hash = await FileHasher.sha256File(context.item.localPath!);
      if (hash != context.item.sha256) {
        throw StateError('Dosya bütünlük doğrulaması başarısız.');
      }
      context.item.status = TransferStatus.completed;
    } catch (e) {
      context.item.status = TransferStatus.failed;
      context.item.errorMessage = e.toString();
    }
    _emit();
  }

  String _safeFileName(String name) {
    return name.replaceAll(RegExp(r'[\\/:*?"<>|]'), '_');
  }

  Future<void> dispose() async {
    await _subscription.cancel();
    for (final completer in _pendingReady.values) {
      if (!completer.isCompleted) {
        completer.completeError(StateError('Bağlantı kapandı'));
      }
    }
    for (final completer in _pendingPongs.values) {
      if (!completer.isCompleted) {
        completer.completeError(StateError('Bağlantı kapandı'));
      }
    }
    for (final completer in _pendingAcks.values) {
      if (!completer.isCompleted) {
        completer.completeError(StateError('Bağlantı kapandı'));
      }
    }
    _pendingReady.clear();
    _pendingPongs.clear();
    _pendingAcks.clear();
    _pendingIncoming.clear();
    _pausedFileIds.clear();
    _cancelledFileIds.clear();
    for (final context in _receiveContexts.values) {
      await context.raf.close();
    }
    _receiveContexts.clear();
    await _transfersController.close();
  }
}

class _OutboundFileJob {
  _OutboundFileJob({
    required this.file,
    required this.item,
    required this.size,
  });

  final File file;
  final TransferFileItem item;
  final int size;
  Completer<void>? readyCompleter;
}

class _PendingIncomingFile {
  _PendingIncomingFile({
    required this.item,
    required this.chunkSize,
  });

  final TransferFileItem item;
  final int chunkSize;
}

class _ReceiveContext {
  _ReceiveContext({
    required this.item,
    required this.raf,
    required this.chunkSize,
  });

  final TransferFileItem item;
  final RandomAccessFile raf;
  final int chunkSize;
}
