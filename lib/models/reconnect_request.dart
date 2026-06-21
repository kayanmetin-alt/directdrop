class ReconnectRequest {
  const ReconnectRequest({
    required this.fromDeviceId,
    required this.fromDeviceName,
    required this.clientCreatedAt,
  });

  final String fromDeviceId;
  final String fromDeviceName;
  final int clientCreatedAt;

  factory ReconnectRequest.fromMap(String fromDeviceId, Map<String, dynamic> map) {
    return ReconnectRequest(
      fromDeviceId: fromDeviceId,
      fromDeviceName: map['fromDeviceName'] as String? ?? 'Cihaz',
      clientCreatedAt: (map['clientCreatedAt'] as num?)?.toInt() ??
          DateTime.now().millisecondsSinceEpoch,
    );
  }
}
