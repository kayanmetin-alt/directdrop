enum PeerRole { host, guest }

class RoomSession {
  const RoomSession({
    required this.roomCode,
    required this.peerId,
    required this.role,
    this.remotePeerId,
    this.deviceName,
  });

  final String roomCode;
  final String peerId;
  final PeerRole role;
  final String? remotePeerId;
  final String? deviceName;

  RoomSession copyWith({
    String? remotePeerId,
    String? deviceName,
  }) {
    return RoomSession(
      roomCode: roomCode,
      peerId: peerId,
      role: role,
      remotePeerId: remotePeerId ?? this.remotePeerId,
      deviceName: deviceName ?? this.deviceName,
    );
  }
}
