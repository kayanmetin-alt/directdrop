class PairedDevice {
  const PairedDevice({
    required this.deviceId,
    required this.displayName,
    required this.platform,
    required this.lastConnectedAt,
  });

  final String deviceId;
  final String displayName;
  final String platform;
  final DateTime lastConnectedAt;

  Map<String, dynamic> toJson() => {
        'deviceId': deviceId,
        'displayName': displayName,
        'platform': platform,
        'lastConnectedAt': lastConnectedAt.toIso8601String(),
      };

  factory PairedDevice.fromJson(Map<String, dynamic> json) {
    return PairedDevice(
      deviceId: json['deviceId'] as String,
      displayName: json['displayName'] as String,
      platform: json['platform'] as String? ?? 'unknown',
      lastConnectedAt: DateTime.tryParse(json['lastConnectedAt'] as String? ?? '') ??
          DateTime.fromMillisecondsSinceEpoch(0),
    );
  }

  PairedDevice copyWith({
    String? displayName,
    DateTime? lastConnectedAt,
  }) {
    return PairedDevice(
      deviceId: deviceId,
      displayName: displayName ?? this.displayName,
      platform: platform,
      lastConnectedAt: lastConnectedAt ?? this.lastConnectedAt,
    );
  }
}

enum WakeRequestType {
  connect,
  fileRequest,
}

class WakeRequest {
  const WakeRequest({
    required this.roomCode,
    required this.fromDeviceId,
    required this.fromDeviceName,
    required this.type,
    required this.createdAt,
  });

  final String roomCode;
  final String fromDeviceId;
  final String fromDeviceName;
  final WakeRequestType type;
  final int createdAt;

  factory WakeRequest.fromMap(Map<dynamic, dynamic> map) {
    final typeRaw = map['type'] as String? ?? 'connect';
    return WakeRequest(
      roomCode: (map['roomCode'] as String).trim().toUpperCase(),
      fromDeviceId: map['fromDeviceId'] as String,
      fromDeviceName: map['fromDeviceName'] as String? ?? 'Cihaz',
      type: typeRaw == 'file_request'
          ? WakeRequestType.fileRequest
          : WakeRequestType.connect,
      createdAt: (map['createdAt'] as num?)?.toInt() ?? 0,
    );
  }

  Map<String, dynamic> toMap() => {
        'roomCode': roomCode,
        'fromDeviceId': fromDeviceId,
        'fromDeviceName': fromDeviceName,
        'type': type == WakeRequestType.fileRequest ? 'file_request' : 'connect',
        'createdAt': createdAt,
      };
}
