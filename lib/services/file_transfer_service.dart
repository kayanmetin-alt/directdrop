import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter_webrtc/flutter_webrtc.dart';
import 'package:path/path.dart' as p;
import 'package:uuid/uuid.dart';

import '../models/transfer_file.dart';
import '../models/transfer_restore_state.dart';
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
    _setupIncomingListener();
  }

  FileTransferService._restore({
    required WebRtcService webRtc,
    required TransferRestoreState state,
  }) : _webRtc = webRtc {
    _items.addAll(state.items);
    _pausedFileIds.addAll(state.pausedFileIds);
    _cancelledFileIds.addAll(state.cancelledFileIds);
    _receiveSnapshots = List.from(state.receiveSnapshots);
    _restoredOutboundJobIds = List.from(state.outboundJobIds);
    for (final entry in state.pendingIncomingChunkSizes.entries) {
      TransferFileItem? matched;
      for (final candidate in state.items) {
        if (candidate.id == entry.key) {
          matched = candidate;
          break;
        }
      }
      if (matched == null) continue;
      _pendingIncoming[entry.key] = _PendingIncomingFile(
        item: matched,
        chunkSize: entry.value,
      );
    }
    _setupIncomingListener();
    _emit();
  }

  factory FileTransferService.restore({
    required WebRtcService webRtc,
    required TransferRestoreState state,
  }) {
    return FileTransferService._restore(webRtc: webRtc, state: state);
  }

  static const chunkSize = 65536; // 64 KB
  static const _uuid = Uuid();

  final WebRtcService _webRtc;
  late final StreamSubscription<dynamic> _subscription;

  void _setupIncomingListener() {
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

  final _transfersController =
      StreamController<List<TransferFileItem>>.broadcast();
  Stream<List<TransferFileItem>> get transfers => _transfersController.stream;

  List<TransferFileItem> get currentItems => List<TransferFileItem>.from(_items);

  final List<TransferFileItem> _items = [];
  final Map<String, _ReceiveContext> _receiveContexts = {};
  final Map<String, _PendingIncomingFile> _pendingIncoming = {};
  final Map<String, Completer<void>> _pendingAcks = {};
  final Map<String, Completer<void>> _pendingReady = {};
  final Map<String, Completer<void>> _pendingPongs = {};
  final Set<String> _pausedFileIds = {};
  final Set<String> _cancelledFileIds = {};
  Future<void> _incomingChain = Future.value();

  // Tüm dosya teklifleri (file_start) hemen gönderilir; böylece alıcı tüm
  // listeyi bir anda görüp toplu ya da tek tek onaylayabilir. Onaylanan dosyalar
  // bu kuyruğa eklenir ve parça akışı aynı anda tek dosya olacak şekilde sırayla
  // yapılır (kanal tıkanmasını önlemek için). Sıralama onay sırasını izler.
  final List<_OutboundFileJob> _streamQueue = [];
  bool _streamDraining = false;
  bool _disposed = false;
  List<ReceiveContextSnapshot> _receiveSnapshots = [];
  List<String>? _restoredOutboundJobIds;

  /// Şu an akmakta olan ya da kuyrukta bekleyen giden dosya kimlikleri.
  final Set<String> _streamingFileIds = {};

  /// Diskten geri yüklenip kullanıcının "Devam et"e basmasını bekleyen
  /// (otomatik başlatılmamış) giden dosya kimlikleri.
  final Set<String> _restoredPausedOutbound = {};

  void _enqueueOutboundJob(_OutboundFileJob job) {
    _streamingFileIds.add(job.item.id);
    _streamQueue.add(job);
    _ensureStreamDraining();
  }

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

    // Dosyalar hash'lendi (status: pending = "Bekliyor"). Tüm teklifleri hemen
    // gönder ki alıcı tüm listeyi tek seferde görsün; her dosya onaylandıkça
    // parça akışı kuyruğa girer.
    unawaited(_sendOffers(jobs));
  }

  /// Tüm dosya tekliflerini (file_start) peşinen gönderir. Böylece alıcıda
  /// gelen dosyaların tamamı aynı anda listelenir ve toplu/tekil onaylanabilir.
  Future<void> _sendOffers(List<_OutboundFileJob> jobs) async {
    for (final job in jobs) {
      if (_disposed) return;
      if (_cancelledFileIds.contains(job.item.id)) {
        if (job.item.status != TransferStatus.cancelled) {
          job.item.status = TransferStatus.cancelled;
          _emit();
        }
        continue;
      }

      for (var i = 0; i < 600 && !_webRtc.isDataChannelOpen && !_disposed; i++) {
        await Future<void>.delayed(const Duration(milliseconds: 100));
      }
      if (_disposed) return;
      if (!_webRtc.isDataChannelOpen) {
        job.item.status = TransferStatus.failed;
        job.item.errorMessage = 'Bağlantı hazır değil.';
        _emit();
        continue;
      }

      final readyCompleter = Completer<void>();
      _pendingReady[job.item.id] = readyCompleter;
      job.readyCompleter = readyCompleter;

      job.item.status = TransferStatus.awaitingApproval;
      _emit();

      try {
        await _sendControl({
          'type': 'file_start',
          'id': job.item.id,
          'name': job.item.name,
          'size': job.item.size,
          'sha256': job.item.sha256,
          'chunkSize': chunkSize,
        });
      } catch (e) {
        _pendingReady.remove(job.item.id);
        job.item.status = TransferStatus.failed;
        job.item.errorMessage = 'Teklif gönderilemedi: $e';
        _emit();
        continue;
      }

      // Onay (file_start_ack) gelince dosyayı akış kuyruğuna al.
      unawaited(_awaitApprovalThenQueue(job));
    }
  }

  /// Bir dosyanın onayını (ya da reddini) bekler; onaylanırsa akış kuyruğuna
  /// ekleyip sıralı aktarımı tetikler.
  Future<void> _awaitApprovalThenQueue(_OutboundFileJob job) async {
    final readyCompleter = job.readyCompleter;
    if (readyCompleter == null) return;
    try {
      await readyCompleter.future.timeout(
        const Duration(minutes: 10),
        onTimeout: () => throw TimeoutException(
          'Karşı cihaz dosyayı onaylamadı.',
        ),
      );
    } on TransferRejectedException catch (e) {
      job.item.status = TransferStatus.cancelled;
      job.item.errorMessage = e.message;
      _pendingReady.remove(job.item.id);
      _emit();
      return;
    } catch (e) {
      if (job.item.status != TransferStatus.cancelled) {
        job.item.status = TransferStatus.failed;
        job.item.errorMessage = e.toString();
      }
      _pendingReady.remove(job.item.id);
      _emit();
      return;
    }

    _enqueueOutboundJob(job);
  }

  void _ensureStreamDraining() {
    if (_streamDraining || _disposed) return;
    _streamDraining = true;
    unawaited(_drainStreamQueue());
  }

  Future<void> _drainStreamQueue() async {
    try {
      while (_streamQueue.isNotEmpty && !_disposed) {
        final job = _streamQueue.removeAt(0);
        try {
          await _streamOutbound(job);
        } catch (e) {
          debugPrint('Giden transfer hatası (${job.item.name}): $e');
        } finally {
          _streamingFileIds.remove(job.item.id);
        }
      }
    } finally {
      _streamDraining = false;
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
    item.errorMessage = null;
    _emit();

    // Karşı tarafa da bildir; alıcı offset'ini paylaş ki gönderen doğru yerden
    // (boşluk bırakmadan) sürdürebilsin.
    try {
      await _sendControl({
        'type': 'file_resume',
        'fileId': fileId,
        'bytesTransferred': item.bytesTransferred,
      });
    } catch (_) {}

    // Gönderen tarafta veri akışını başlat (gerekiyorsa yeniden kuyruğa al).
    _ensureOutboundResume(fileId);
  }

  /// Bir giden dosyanın akışını başlatır/sürdürür. Diskten geri yüklenip
  /// bellekte aktif işi olmayan gönderenler için yeni bir akış işi kuyruğa alır.
  void _ensureOutboundResume(String fileId) {
    final item = _itemById(fileId);
    if (item == null) return;
    if (item.direction != TransferDirection.sending) return;
    if (item.localPath == null) return;
    if (item.bytesTransferred >= item.size) return;

    _restoredPausedOutbound.remove(fileId);
    _pausedFileIds.remove(fileId);
    if (item.status == TransferStatus.paused ||
        item.status == TransferStatus.failed) {
      item.status = TransferStatus.inProgress;
      item.errorMessage = null;
    }

    // Halihazırda kuyrukta/akışta olan bir iş varsa tekrar ekleme; yalnızca
    // duraklama bayrağını kaldırmak akışı sürdürür.
    if (_streamingFileIds.contains(fileId)) {
      _emit();
      return;
    }

    _enqueueOutboundJob(
      _OutboundFileJob(
        file: File(item.localPath!),
        item: item,
        size: item.size,
      ),
    );
    _emit();
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

  bool _canResumeTransfer(TransferFileItem item) {
    return item.bytesTransferred > 0 &&
        item.bytesTransferred < item.size &&
        (item.status == TransferStatus.inProgress ||
            item.status == TransferStatus.paused ||
            item.status == TransferStatus.failed);
  }

  void _markInterrupted(TransferFileItem item) {
    if (item.status == TransferStatus.completed ||
        item.status == TransferStatus.cancelled ||
        item.status == TransferStatus.awaitingApproval ||
        item.status == TransferStatus.pending) {
      return;
    }
    if (item.bytesTransferred > 0 && item.bytesTransferred < item.size) {
      item.status = TransferStatus.paused;
      _pausedFileIds.add(item.id);
      item.errorMessage = null;
    } else if (item.status == TransferStatus.inProgress) {
      item.status = TransferStatus.failed;
      item.errorMessage ??= 'Bağlantı kesildi';
    }
  }

  /// Uygulama arka plana geçerken UI'da duraklatılmış göster (kopma beklentisi).
  void prepareForBackgroundInterrupt() {
    if (_disposed) return;
    for (final item in _items) {
      if (item.status == TransferStatus.inProgress) {
        item.status = TransferStatus.paused;
        _pausedFileIds.add(item.id);
      }
    }
    _emit();
  }

  /// WebRTC yeniden bağlanmadan önce transfer durumunu korur.
  Future<TransferRestoreState> detachForReconnect() async {
    _disposed = true;
    _streamDraining = false;
    await _subscription.cancel();

    for (final item in _items) {
      _markInterrupted(item);
    }

    final receiveSnapshots = _receiveContexts.values
        .map(
          (ctx) => ReceiveContextSnapshot(
            item: ctx.item,
            chunkSize: ctx.chunkSize,
          ),
        )
        .toList();

    for (final context in _receiveContexts.values) {
      try {
        await context.raf.close();
      } catch (_) {}
    }
    _receiveContexts.clear();

    _pendingAcks.clear();
    for (final completer in _pendingReady.values) {
      if (!completer.isCompleted) {
        completer.completeError(StateError('Bağlantı yenileniyor'));
      }
    }
    _pendingReady.clear();
    for (final completer in _pendingPongs.values) {
      if (!completer.isCompleted) {
        completer.completeError(StateError('Bağlantı yenileniyor'));
      }
    }
    _pendingPongs.clear();

    final outboundJobIds = <String>[];
    for (final job in _streamQueue) {
      outboundJobIds.add(job.item.id);
    }
    _streamQueue.clear();

    for (final item in _items) {
      if (item.direction != TransferDirection.sending) continue;
      if (item.localPath == null) continue;
      if (item.bytesTransferred >= item.size) continue;
      if (item.status == TransferStatus.paused ||
          item.status == TransferStatus.inProgress) {
        if (!outboundJobIds.contains(item.id)) {
          outboundJobIds.add(item.id);
        }
      }
    }

    final pendingIncomingChunkSizes = {
      for (final entry in _pendingIncoming.entries)
        entry.key: entry.value.chunkSize,
    };

    return TransferRestoreState(
      items: List<TransferFileItem>.from(_items),
      receiveSnapshots: receiveSnapshots,
      outboundJobIds: outboundJobIds,
      pausedFileIds: Set.from(_pausedFileIds),
      cancelledFileIds: Set.from(_cancelledFileIds),
      pendingIncomingChunkSizes: pendingIncomingChunkSizes,
    );
  }

  /// Yeni veri kanalı açıldıktan sonra yarım kalan transferleri sürdürür.
  ///
  /// [autoResume] false ise (uygulama tamamen kapanıp açıldıktan sonra diskten
  /// geri yükleme), transferler otomatik başlatılmaz; alıcı RAF'ları yeniden
  /// açılır ve karşı tarafla ofsetler eşitlenir, ancak dosyalar "duraklatıldı"
  /// olarak kalır. Kullanıcı her dosyadaki Play düğmesiyle devam ettirir.
  Future<void> resumeAfterReconnect({bool autoResume = true}) async {
    if (_disposed) return;

    final hasWork = (_restoredOutboundJobIds?.isNotEmpty ?? false) ||
        _receiveSnapshots.isNotEmpty ||
        _items.any(_canResumeTransfer);
    if (!hasWork) return;

    await ensurePeerReady();

    try {
      await _sendControl({
        'type': 'transfer_sync',
        'files': [
          for (final item in _items)
            if (_canResumeTransfer(item) ||
                item.status == TransferStatus.paused)
              {
                'fileId': item.id,
                'bytesTransferred': item.bytesTransferred,
              },
        ],
      });
    } catch (_) {}

    for (final snap in _receiveSnapshots) {
      if (snap.item.bytesTransferred < snap.item.size) {
        await _reopenReceiveContext(snap);
      }
    }
    _receiveSnapshots = [];

    if (!autoResume) {
      await _prepareRestoredAsPaused();
      return;
    }

    for (final item in _items) {
      if (item.direction == TransferDirection.sending &&
          item.status == TransferStatus.awaitingApproval) {
        await _resendOfferForItem(item);
      }
    }

    final jobIds = _restoredOutboundJobIds ?? [];
    _restoredOutboundJobIds = null;
    for (final fileId in jobIds) {
      final item = _itemById(fileId);
      if (item == null || item.localPath == null) continue;
      if (item.bytesTransferred >= item.size) continue;

      _pausedFileIds.remove(fileId);
      item.status = TransferStatus.inProgress;
      item.errorMessage = null;
      _enqueueOutboundJob(
        _OutboundFileJob(
          file: File(item.localPath!),
          item: item,
          size: item.size,
        ),
      );
      try {
        await _sendControl({'type': 'file_resume', 'fileId': fileId});
      } catch (_) {}
    }

    for (final id in _pausedFileIds.toList()) {
      final item = _itemById(id);
      if (item?.direction == TransferDirection.receiving &&
          item!.bytesTransferred < item.size) {
        _pausedFileIds.remove(id);
        item.status = TransferStatus.inProgress;
        try {
          await _sendControl({'type': 'file_resume', 'fileId': id});
        } catch (_) {}
      }
    }

    _emit();
    _ensureStreamDraining();
  }

  /// Diskten geri yüklenen transferleri "duraklatıldı" olarak hazır bekletir;
  /// kullanıcı Play düğmesine basana kadar veri akmaz.
  Future<void> _prepareRestoredAsPaused() async {
    final jobIds = _restoredOutboundJobIds ?? [];
    _restoredOutboundJobIds = null;
    for (final fileId in jobIds) {
      final item = _itemById(fileId);
      if (item == null || item.localPath == null) continue;
      if (item.bytesTransferred >= item.size) continue;
      _restoredPausedOutbound.add(fileId);
    }

    for (final item in _items) {
      if (item.bytesTransferred > 0 &&
          item.bytesTransferred < item.size &&
          item.status != TransferStatus.completed &&
          item.status != TransferStatus.cancelled) {
        item.status = TransferStatus.paused;
        _pausedFileIds.add(item.id);
        item.errorMessage = null;
      }
    }
    _emit();
  }

  Future<void> _resendOfferForItem(TransferFileItem item) async {
    final readyCompleter = Completer<void>();
    _pendingReady[item.id] = readyCompleter;

    try {
      await _sendControl({
        'type': 'file_start',
        'id': item.id,
        'name': item.name,
        'size': item.size,
        'sha256': item.sha256,
        'chunkSize': chunkSize,
        'resumeFromBytes': item.bytesTransferred,
      });
    } catch (e) {
      _pendingReady.remove(item.id);
      item.status = TransferStatus.failed;
      item.errorMessage = 'Teklif gönderilemedi: $e';
      _emit();
      return;
    }

    final job = _OutboundFileJob(
      file: File(item.localPath!),
      item: item,
      size: item.size,
      readyCompleter: readyCompleter,
    );
    unawaited(_awaitApprovalThenQueue(job));
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

  /// Onaylanmış bir dosyanın parçalarını akıtır. Kuyruktan sırayla çağrılır;
  /// aynı anda yalnızca bir dosya akar.
  Future<void> _streamOutbound(_OutboundFileJob job) async {
    final fileId = job.item.id;
    final item = job.item;
    final file = job.file;
    final statSize = job.size;

    try {
      if (_cancelledFileIds.contains(fileId)) {
        throw TransferCancelledException();
      }

      item.status = TransferStatus.inProgress;
      _emit();

      final raf = await file.open(mode: FileMode.read);
      try {
        var offset = item.bytesTransferred;
        var chunkIndex = offset ~/ chunkSize;
        if (offset > 0) {
          await raf.setPosition(offset);
        }
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
    } on TransferCancelledException catch (e) {
      if (item.status != TransferStatus.cancelled) {
        item.status = TransferStatus.cancelled;
        item.errorMessage = e.message;
      }
    } catch (e) {
      if (_canResumeTransfer(item)) {
        item.status = TransferStatus.paused;
        _pausedFileIds.add(item.id);
        item.errorMessage = null;
      } else {
        item.status = TransferStatus.failed;
        item.errorMessage = e.toString();
      }
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
      case 'transfer_sync':
        await _handleTransferSync(payload);
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
        if (resumedItem != null) {
          // Biz göndericiysek: alıcının diskte sahip olduğu bayt sayısına geri
          // sar; böylece yeniden başlatmada boşluk kalmaz.
          if (resumedItem.direction == TransferDirection.sending) {
            final remoteBytes = (payload['bytesTransferred'] as num?)?.toInt();
            if (remoteBytes != null &&
                remoteBytes >= 0 &&
                remoteBytes < resumedItem.bytesTransferred) {
              resumedItem.bytesTransferred = remoteBytes;
            }
          }
          if (resumedItem.status == TransferStatus.paused) {
            resumedItem.status = TransferStatus.inProgress;
            resumedItem.errorMessage = null;
          }
          _emit();
        }
        // Karşı taraf Play'e bastı ve biz göndericiysek (özellikle diskten geri
        // yüklenmiş bir oturumda) veri akışını başlat.
        _ensureOutboundResume(resumeFileId);
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
    final existing = _itemById(fileId);
    if (existing != null) {
      if (existing.status == TransferStatus.awaitingApproval) {
        return;
      }
      if (_canResumeTransfer(existing) ||
          existing.status == TransferStatus.paused) {
        return;
      }
    }

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

  Future<void> _handleTransferSync(Map<String, dynamic> payload) async {
    final files = payload['files'] as List<dynamic>? ?? [];
    for (final raw in files) {
      if (raw is! Map) continue;
      final map = Map<String, dynamic>.from(raw);
      final fileId = map['fileId'] as String? ?? '';
      if (fileId.isEmpty) continue;
      var remoteBytes = (map['bytesTransferred'] as num?)?.toInt() ?? 0;
      final item = _itemById(fileId);
      if (item == null) continue;
      if (remoteBytes < 0) remoteBytes = 0;
      if (remoteBytes > item.size) remoteBytes = item.size;

      if (item.direction == TransferDirection.sending) {
        // Alıcının diskte gerçekten sahip olduğu bayt sayısına geri sar; böylece
        // yeniden başlatmada boşluk/atlanan parça olmaz (alıcı otoritedir).
        if (remoteBytes < item.bytesTransferred) {
          item.bytesTransferred = remoteBytes;
        }
      }
      // Alıcı tarafta yerel disk otoritedir; uzak değeri yok say.
    }
    _emit();
  }

  Future<void> _beginReceiveFile(_PendingIncomingFile pending) async {
    final fileId = pending.item.id;
    final existing = _receiveContexts[fileId];
    if (existing != null) return;

    final name = pending.item.name;
    final item = pending.item;

    final downloadsDir =
        await DownloadDirectoryService.instance.ensureDownloadsDirectory();

    final localPath = item.localPath ??
        p.join(
          downloadsDir.path,
          '${DateTime.now().millisecondsSinceEpoch}_${_safeFileName(name)}',
        );
    final file = File(localPath);
    if (!await file.exists()) {
      await file.create(recursive: true);
    }

    final raf = await file.open(mode: FileMode.write);
    if (item.bytesTransferred > 0) {
      await raf.setPosition(item.bytesTransferred);
    }

    item.localPath = localPath;
    _receiveContexts[fileId] = _ReceiveContext(
      item: item,
      raf: raf,
      chunkSize: pending.chunkSize,
    );
    _emit();
  }

  Future<void> _reopenReceiveContext(ReceiveContextSnapshot snap) async {
    final fileId = snap.item.id;
    if (_receiveContexts.containsKey(fileId)) return;

    final item = _itemById(fileId);
    if (item == null) return;

    final localPath = item.localPath ?? snap.item.localPath;
    if (localPath == null) {
      await _beginReceiveFile(
        _PendingIncomingFile(item: item, chunkSize: snap.chunkSize),
      );
      return;
    }

    final file = File(localPath);
    if (!await file.exists()) {
      await file.create(recursive: true);
    }

    final raf = await file.open(mode: FileMode.write);
    if (item.bytesTransferred > 0) {
      await raf.setPosition(item.bytesTransferred);
    }

    item.localPath = localPath;
    item.status = TransferStatus.inProgress;
    _receiveContexts[fileId] = _ReceiveContext(
      item: item,
      raf: raf,
      chunkSize: snap.chunkSize,
    );
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
    _disposed = true;
    _streamQueue.clear();
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
    this.readyCompleter,
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
