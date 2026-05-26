enum SignalingType {
  offer,
  answer,
  iceCandidate,
  peerJoined,
  peerLeft,
}

class SignalingMessage {
  const SignalingMessage({
    required this.type,
    required this.fromPeerId,
    required this.toPeerId,
    this.sdp,
    this.candidate,
    this.sdpMid,
    this.sdpMLineIndex,
    this.timestamp,
  });

  final SignalingType type;
  final String fromPeerId;
  final String toPeerId;
  final String? sdp;
  final String? candidate;
  final String? sdpMid;
  final int? sdpMLineIndex;
  final int? timestamp;

  Map<String, dynamic> toJson() => {
        'type': type.name,
        'fromPeerId': fromPeerId,
        'toPeerId': toPeerId,
        if (sdp != null) 'sdp': sdp,
        if (candidate != null) 'candidate': candidate,
        if (sdpMid != null) 'sdpMid': sdpMid,
        if (sdpMLineIndex != null) 'sdpMLineIndex': sdpMLineIndex,
        'timestamp': timestamp ?? DateTime.now().millisecondsSinceEpoch,
      };

  factory SignalingMessage.fromJson(Map<dynamic, dynamic> json) {
    return SignalingMessage(
      type: SignalingType.values.byName(json['type'] as String),
      fromPeerId: json['fromPeerId'] as String,
      toPeerId: json['toPeerId'] as String,
      sdp: json['sdp'] as String?,
      candidate: json['candidate'] as String?,
      sdpMid: json['sdpMid'] as String?,
      sdpMLineIndex: json['sdpMLineIndex'] as int?,
      timestamp: json['timestamp'] as int?,
    );
  }
}
