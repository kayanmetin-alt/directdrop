import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../models/transfer_file.dart';
import '../models/transfer_history_record.dart';

class TransferHistoryService extends ChangeNotifier {
  TransferHistoryService._();

  static final TransferHistoryService instance = TransferHistoryService._();

  static const _storageKey = 'directdrop_transfer_history';
  static const _maxRecords = 500;

  List<TransferHistoryRecord> _records = [];
  bool _loaded = false;

  List<TransferHistoryRecord> get records => List.unmodifiable(_records);

  List<TransferHistoryRecord> recordsForPeer(String peerDeviceId) {
    return _records.where((r) => r.peerDeviceId == peerDeviceId).toList();
  }

  Future<void> load() async {
    if (_loaded) return;
    final prefs = await SharedPreferences.getInstance();
    final raw = prefs.getString(_storageKey);
    if (raw != null && raw.isNotEmpty) {
      try {
        final list = jsonDecode(raw) as List<dynamic>;
        _records = list
            .map(
              (e) => TransferHistoryRecord.fromJson(
                Map<String, dynamic>.from(e as Map),
              ),
            )
            .toList()
          ..sort((a, b) => a.completedAt.compareTo(b.completedAt));
      } catch (e) {
        debugPrint('Transfer geçmişi okunamadı: $e');
      }
    }
    _loaded = true;
    notifyListeners();
  }

  Future<void> addFromTransfer({
    required TransferFileItem item,
    required String peerDeviceId,
    required String peerName,
  }) async {
    await load();

    final record = TransferHistoryRecord(
      id: item.id,
      peerDeviceId: peerDeviceId,
      peerName: peerName,
      fileName: item.name,
      fileSize: item.size,
      direction: item.direction,
      status: item.status,
      completedAt: DateTime.now(),
      localPath: item.localPath,
      errorMessage: item.errorMessage,
    );

    _records.removeWhere((r) => r.id == record.id);
    _records.add(record);
    _records.sort((a, b) => a.completedAt.compareTo(b.completedAt));

    if (_records.length > _maxRecords) {
      _records.removeRange(0, _records.length - _maxRecords);
    }

    await _persist();
    notifyListeners();
  }

  Future<void> clearAll() async {
    await load();
    _records.clear();
    await _persist();
    notifyListeners();
  }

  Future<void> clearForPeer(String peerDeviceId) async {
    await load();
    _records.removeWhere((r) => r.peerDeviceId == peerDeviceId);
    await _persist();
    notifyListeners();
  }

  Future<void> _persist() async {
    final prefs = await SharedPreferences.getInstance();
    final encoded = jsonEncode(_records.map((r) => r.toJson()).toList());
    await prefs.setString(_storageKey, encoded);
  }
}
