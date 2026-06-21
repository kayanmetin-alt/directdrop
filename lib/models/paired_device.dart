class PairedDevice {
  const PairedDevice({
    required this.deviceId,
    required this.displayName,
    required this.platform,
    required this.lastConnectedAt,
    this.inviteCode,
  });

  final String deviceId;
  final String displayName;
  final String platform;
  final DateTime lastConnectedAt;
  /// Kalıcı QR kodu — yeniden kurulumda güncel deviceId çözümlemek için.
  final String? inviteCode;

  Map<String, dynamic> toJson() => {
        'deviceId': deviceId,
        'displayName': displayName,
        'platform': platform,
        'lastConnectedAt': lastConnectedAt.toIso8601String(),
        if (inviteCode != null) 'inviteCode': inviteCode,
      };

  factory PairedDevice.fromJson(Map<String, dynamic> json) {
    return PairedDevice(
      deviceId: json['deviceId'] as String,
      displayName: json['displayName'] as String,
      platform: json['platform'] as String? ?? 'unknown',
      lastConnectedAt: DateTime.tryParse(json['lastConnectedAt'] as String? ?? '') ??
          DateTime.fromMillisecondsSinceEpoch(0),
      inviteCode: json['inviteCode'] as String?,
    );
  }

  PairedDevice copyWith({
    String? deviceId,
    String? displayName,
    DateTime? lastConnectedAt,
    String? inviteCode,
  }) {
    return PairedDevice(
      deviceId: deviceId ?? this.deviceId,
      displayName: displayName ?? this.displayName,
      platform: platform,
      lastConnectedAt: lastConnectedAt ?? this.lastConnectedAt,
      inviteCode: inviteCode ?? this.inviteCode,
    );
  }
}

enum WakeRequestType {
  connect,
  fileRequest,
  reconnect,
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
    WakeRequestType type;
    switch (typeRaw) {
      case 'file_request':
        type = WakeRequestType.fileRequest;
        break;
      case 'reconnect':
        type = WakeRequestType.reconnect;
        break;
      default:
        type = WakeRequestType.connect;
    }
    final roomRaw = map['roomCode'] as String? ?? '';
    return WakeRequest(
      roomCode: roomRaw.trim().toUpperCase(),
      fromDeviceId: map['fromDeviceId'] as String? ?? '',
      fromDeviceName: map['fromDeviceName'] as String? ?? 'Cihaz',
      type: type,
      createdAt: (map['createdAt'] as num?)?.toInt() ?? 0,
    );
  }

  Map<String, dynamic> toMap() => {
        if (roomCode.isNotEmpty) 'roomCode': roomCode,
        'fromDeviceId': fromDeviceId,
        'fromDeviceName': fromDeviceName,
        'type': switch (type) {
          WakeRequestType.fileRequest => 'file_request',
          WakeRequestType.reconnect => 'reconnect',
          WakeRequestType.connect => 'connect',
        },
        'createdAt': createdAt,
      };
}
