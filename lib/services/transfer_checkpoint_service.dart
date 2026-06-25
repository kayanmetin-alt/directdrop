import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:path_provider/path_provider.dart';

import '../models/transfer_checkpoint.dart';
import '../models/transfer_file.dart';
import '../models/transfer_restore_state.dart';
import 'file_transfer_service.dart';

/// Yarım kalan transferleri diske yazar; uygulama tamamen kapansa bile okunur.
class TransferCheckpointService {
  TransferCheckpointService._();

  static final TransferCheckpointService instance = TransferCheckpointService._();

  static const _fileName = 'transfer_checkpoints.json';

  List<TransferCheckpoint>? _cache;

  Future<File> _storageFile() async {
    final dir = await getApplicationSupportDirectory();
    return File('${dir.path}/$_fileName');
  }

  Future<List<TransferCheckpoint>> _loadAll() async {
    if (_cache != null) return List.from(_cache!);
    try {
      final file = await _storageFile();
      if (!await file.exists()) {
        _cache = [];
        return [];
      }
      final raw = await file.readAsString();
      if (raw.trim().isEmpty) {
        _cache = [];
        return [];
      }
      final decoded = jsonDecode(raw) as Map<String, dynamic>;
      final list = decoded['checkpoints'] as List<dynamic>? ?? [];
      _cache = list
          .map(
            (entry) => TransferCheckpoint.fromJson(
              Map<String, dynamic>.from(entry as Map),
            ),
          )
          .toList();
      return List.from(_cache!);
    } catch (e) {
      debugPrint('Transfer checkpoint okunamadı: $e');
      _cache = [];
      return [];
    }
  }

  Future<void> _saveAll(List<TransferCheckpoint> checkpoints) async {
    _cache = List.from(checkpoints);
    try {
      final file = await _storageFile();
      await file.parent.create(recursive: true);
      await file.writeAsString(
        jsonEncode({
          'version': 1,
          'checkpoints': checkpoints.map((cp) => cp.toJson()).toList(),
        }),
      );
    } catch (e) {
      debugPrint('Transfer checkpoint yazılamadı: $e');
    }
  }

  bool _isCheckpointable(TransferFileItem item) {
    if (item.status == TransferStatus.completed ||
        item.status == TransferStatus.cancelled) {
      return false;
    }
    return item.bytesTransferred > 0 && item.bytesTransferred < item.size;
  }

  TransferStatus _persistedStatus(TransferStatus status) {
    if (status == TransferStatus.inProgress ||
        status == TransferStatus.queued ||
        status == TransferStatus.failed) {
      return TransferStatus.paused;
    }
    return status;
  }

  Future<void> syncSession({
    required String peerDeviceId,
    required String peerDisplayName,
    required List<TransferFileItem> items,
  }) async {
    final checkpointable = items.where(_isCheckpointable).toList();
    final all = await _loadAll();
    final others =
        all.where((cp) => cp.peerDeviceId != peerDeviceId).toList();

    if (checkpointable.isEmpty) {
      if (others.length != all.length) {
        await _saveAll(others);
      }
      return;
    }

    final now = DateTime.now().millisecondsSinceEpoch;
    final updated = [
      ...others,
      for (final item in checkpointable)
        TransferCheckpoint(
          fileId: item.id,
          peerDeviceId: peerDeviceId,
          peerDisplayName: peerDisplayName,
          name: item.name,
          size: item.size,
          bytesTransferred: item.bytesTransferred,
          direction: item.direction,
          status: _persistedStatus(item.status),
          chunkSize: FileTransferService.chunkSize,
          updatedAtMs: now,
          localPath: item.localPath,
          sha256: item.sha256,
          mimeType: item.mimeType,
        ),
    ];
    await _saveAll(updated);
  }

  Future<void> remove(String fileId) async {
    final all = await _loadAll();
    final next = all.where((cp) => cp.fileId != fileId).toList();
    if (next.length == all.length) return;
    await _saveAll(next);
  }

  Future<void> clearForPeer(String peerDeviceId) async {
    final all = await _loadAll();
    final next = all.where((cp) => cp.peerDeviceId != peerDeviceId).toList();
    if (next.length == all.length) return;
    await _saveAll(next);
  }

  Future<bool> _validateCheckpoint(TransferCheckpoint cp) async {
    if (cp.bytesTransferred <= 0 || cp.bytesTransferred >= cp.size) {
      return false;
    }
    final path = cp.localPath;
    if (path == null || path.isEmpty) return false;
    final file = File(path);
    if (!await file.exists()) return false;
    final length = await file.length();
    if (length < cp.bytesTransferred) return false;
    return true;
  }

  Future<void> pruneInvalid() async {
    final all = await _loadAll();
    final valid = <TransferCheckpoint>[];
    for (final cp in all) {
      if (await _validateCheckpoint(cp)) {
        valid.add(cp);
      }
    }
    if (valid.length != all.length) {
      await _saveAll(valid);
    }
  }

  Future<List<InterruptedTransferGroup>> loadInterruptedGroups() async {
    final all = await _loadAll();
    final byPeer = <String, List<TransferCheckpoint>>{};
    for (final cp in all) {
      if (!await _validateCheckpoint(cp)) continue;
      byPeer.putIfAbsent(cp.peerDeviceId, () => []).add(cp);
    }

    return byPeer.entries
        .map(
          (entry) => InterruptedTransferGroup(
            peerDeviceId: entry.key,
            peerDisplayName: entry.value.first.peerDisplayName,
            checkpoints: entry.value,
          ),
        )
        .toList()
      ..sort(
        (a, b) => b.checkpoints
            .map((cp) => cp.updatedAtMs)
            .reduce((x, y) => x > y ? x : y)
            .compareTo(
              a.checkpoints
                  .map((cp) => cp.updatedAtMs)
                  .reduce((x, y) => x > y ? x : y),
            ),
      );
  }

  Future<TransferRestoreState?> buildRestoreState(String peerDeviceId) async {
    final all = await _loadAll();
    final peerCheckpoints = <TransferCheckpoint>[];
    for (final cp in all) {
      if (cp.peerDeviceId != peerDeviceId) continue;
      if (await _validateCheckpoint(cp)) {
        peerCheckpoints.add(cp);
      }
    }
    if (peerCheckpoints.isEmpty) return null;
    return _toRestoreState(peerCheckpoints);
  }

  TransferRestoreState _toRestoreState(List<TransferCheckpoint> checkpoints) {
    final items = <TransferFileItem>[];
    final receiveSnapshots = <ReceiveContextSnapshot>[];
    final outboundJobIds = <String>[];
    final pausedFileIds = <String>{};
    const cancelledFileIds = <String>{};
    final pendingIncomingChunkSizes = <String, int>{};

    for (final cp in checkpoints) {
      final item = TransferFileItem(
        id: cp.fileId,
        name: cp.name,
        size: cp.size,
        direction: cp.direction,
        mimeType: cp.mimeType,
        localPath: cp.localPath,
        sha256: cp.sha256,
        bytesTransferred: cp.bytesTransferred,
        status: cp.status == TransferStatus.failed
            ? TransferStatus.paused
            : cp.status,
      );
      items.add(item);
      pausedFileIds.add(cp.fileId);

      if (cp.direction == TransferDirection.receiving) {
        receiveSnapshots.add(
          ReceiveContextSnapshot(item: item, chunkSize: cp.chunkSize),
        );
        pendingIncomingChunkSizes[cp.fileId] = cp.chunkSize;
      } else if (cp.bytesTransferred < cp.size) {
        outboundJobIds.add(cp.fileId);
      }
    }

    return TransferRestoreState(
      items: items,
      receiveSnapshots: receiveSnapshots,
      outboundJobIds: outboundJobIds,
      pausedFileIds: pausedFileIds,
      cancelledFileIds: cancelledFileIds,
      pendingIncomingChunkSizes: pendingIncomingChunkSizes,
    );
  }
}
