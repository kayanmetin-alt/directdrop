import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter_webrtc/flutter_webrtc.dart';

import '../models/signaling_message.dart';
import 'firebase_signaling_service.dart';

enum WebRtcConnectionState {
  idle,
  connecting,
  connected,
  failed,
  disconnected,
}

class WebRtcService {
  WebRtcService({
    required FirebaseSignalingService signaling,
    required String localPeerId,
    required String remotePeerId,
    required bool isInitiator,
  })  : _signaling = signaling,
        _localPeerId = localPeerId,
        _remotePeerId = remotePeerId,
        _isInitiator = isInitiator;

  final FirebaseSignalingService _signaling;
  final String _localPeerId;
  final String _remotePeerId;
  final bool _isInitiator;

  RTCPeerConnection? _peerConnection;
  RTCDataChannel? _dataChannel;

  final _connectionStateController =
      StreamController<WebRtcConnectionState>.broadcast();
  final _incomingDataController = StreamController<dynamic>.broadcast();

  Stream<WebRtcConnectionState> get connectionState =>
      _connectionStateController.stream;
  Stream<dynamic> get incomingData => _incomingDataController.stream;

  WebRtcConnectionState _state = WebRtcConnectionState.idle;
  WebRtcConnectionState get state => _state;
  bool _disposed = false;
  bool _remoteDescriptionSet = false;
  final List<RTCIceCandidate> _pendingCandidates = [];
  final List<SignalingMessage> _pendingSignalingMessages = [];

  // Müzakere sağlamlığı için durum.
  String? _localOfferSdp;
  String? _localAnswerSdp;
  String? _lastRemoteOfferSdp;
  Timer? _offerRetryTimer;
  Timer? _answerRetryTimer;
  Timer? _connectionSyncTimer;
  int _offerAttempts = 0;
  int _answerAttempts = 0;
  int _duplicateOfferWhileConnecting = 0;
  // İlk offer/answer kaybolursa hızlı toparlanma için sık ama sınırlı yineleme.
  static const _offerRetryInterval = Duration(milliseconds: 900);
  static const _maxOfferAttempts = 10;
  static const _maxAnswerAttempts = 10;
  static const _connectionSyncInterval = Duration(milliseconds: 500);

  // Opsiyonel özel TURN sunucusu (ör. ücretsiz Metered hesabı). Derlerken:
  //   flutter build windows --release \
  //     --dart-define=DIRECTDROP_TURN_URL=turn:global.relay.metered.ca:443?transport=tcp \
  //     --dart-define=DIRECTDROP_TURN_USERNAME=... \
  //     --dart-define=DIRECTDROP_TURN_CREDENTIAL=...
  // Tanımlıysa farklı ağlardaki (Mac ↔ Windows) cihazlar güvenilir şekilde
  // relay üzerinden bağlanır; aynı ağda zaten doğrudan P2P kullanılır.
  static const _customTurnUrl =
      String.fromEnvironment('DIRECTDROP_TURN_URL');
  static const _customTurnUsername =
      String.fromEnvironment('DIRECTDROP_TURN_USERNAME');
  static const _customTurnCredential =
      String.fromEnvironment('DIRECTDROP_TURN_CREDENTIAL');

  static List<Map<String, dynamic>> get _iceServers {
    final servers = <Map<String, dynamic>>[
      {'urls': 'stun:stun.l.google.com:19302'},
      {'urls': 'stun:stun1.l.google.com:19302'},
      {'urls': 'stun:stun2.l.google.com:19302'},
    ];

    if (_customTurnUrl.isNotEmpty) {
      servers.add({
        'urls': _customTurnUrl,
        if (_customTurnUsername.isNotEmpty) 'username': _customTurnUsername,
        if (_customTurnCredential.isNotEmpty)
          'credential': _customTurnCredential,
      });
    } else {
      // Özel TURN tanımlı değilse: NAT/firewall arkasındaki cihazlar için
      // ücretsiz açık relay (öncelikle 443/TLS — kurumsal firewall'ları aşar).
      servers.addAll(const [
        {
          'urls': 'turn:openrelay.metered.ca:443?transport=tcp',
          'username': 'openrelayproject',
          'credential': 'openrelayproject',
        },
        {
          'urls': 'turns:openrelay.metered.ca:443?transport=tcp',
          'username': 'openrelayproject',
          'credential': 'openrelayproject',
        },
        {
          'urls': 'turn:openrelay.metered.ca:443',
          'username': 'openrelayproject',
          'credential': 'openrelayproject',
        },
        {
          'urls': 'turn:openrelay.metered.ca:80',
          'username': 'openrelayproject',
          'credential': 'openrelayproject',
        },
      ]);
    }

    return servers;
  }

  Future<void> initialize() async {
    _setState(WebRtcConnectionState.connecting);
    _remoteDescriptionSet = false;
    _pendingCandidates.clear();

    _peerConnection = await createPeerConnection({
      'iceServers': _iceServers,
      'sdpSemantics': 'unified-plan',
      // Adayları önceden topla — bağlantı kurulumunu hızlandırır.
      'iceCandidatePoolSize': 4,
    });

    _peerConnection!.onIceCandidate = (candidate) async {
      if (candidate.candidate == null || _disposed) return;
      try {
        await _signaling.sendMessage(
          SignalingMessage(
            type: SignalingType.iceCandidate,
            fromPeerId: _localPeerId,
            toPeerId: _remotePeerId,
            candidate: candidate.candidate,
            sdpMid: candidate.sdpMid,
            sdpMLineIndex: candidate.sdpMLineIndex,
          ),
        );
      } catch (e) {
        debugPrint('ICE candidate gönderilemedi: $e');
      }
    };

    _peerConnection!.onConnectionState = (state) {
      if (_disposed) return;
      debugPrint('WebRTC connection state: $state');
      switch (state) {
        case RTCPeerConnectionState.RTCPeerConnectionStateConnected:
          _stopOfferRetry();
          _stopAnswerRetry();
          _setState(WebRtcConnectionState.connected);
        case RTCPeerConnectionState.RTCPeerConnectionStateFailed:
          _setState(WebRtcConnectionState.failed);
        case RTCPeerConnectionState.RTCPeerConnectionStateDisconnected:
        case RTCPeerConnectionState.RTCPeerConnectionStateClosed:
          _setState(WebRtcConnectionState.disconnected);
        default:
          break;
      }
    };

    _peerConnection!.onIceConnectionState = (state) {
      if (_disposed) return;
      debugPrint('ICE connection state: $state');
      switch (state) {
        case RTCIceConnectionState.RTCIceConnectionStateConnected:
        case RTCIceConnectionState.RTCIceConnectionStateCompleted:
          _stopOfferRetry();
          _stopAnswerRetry();
          if (_state != WebRtcConnectionState.connected) {
            _setState(WebRtcConnectionState.connected);
          }
        case RTCIceConnectionState.RTCIceConnectionStateFailed:
          _setState(WebRtcConnectionState.failed);
        case RTCIceConnectionState.RTCIceConnectionStateDisconnected:
          if (_state == WebRtcConnectionState.connected) {
            _setState(WebRtcConnectionState.disconnected);
          }
        default:
          break;
      }
    };

    _peerConnection!.onDataChannel = (channel) {
      _attachDataChannel(channel);
    };

    if (_isInitiator) {
      _dataChannel = await _peerConnection!.createDataChannel(
        'directdrop',
        RTCDataChannelInit()
          ..ordered = true
          ..maxRetransmits = 30,
      );
      _attachDataChannel(_dataChannel!);

      // Karşı taraf odaya katıldığında signaling dinleyicisi zaten kuruludur;
      // kısa bir bekleme yeterli.
      await Future<void>.delayed(const Duration(milliseconds: 120));
      await _createAndSendOffer();
      _startOfferRetry();
    }

    await _flushPendingSignalingMessages();
    _startConnectionSync();
  }

  Future<void> _createAndSendOffer() async {
    final pc = _peerConnection;
    if (pc == null || _disposed) return;
    try {
      final offer = await pc.createOffer();
      await pc.setLocalDescription(offer);
      _localOfferSdp = offer.sdp;
      await _sendOfferMessage();
    } catch (e) {
      debugPrint('Offer oluşturulamadı: $e');
    }
  }

  Future<void> _sendOfferMessage() async {
    final sdp = _localOfferSdp;
    if (sdp == null || _disposed) return;
    try {
      await _signaling.sendMessage(
        SignalingMessage(
          type: SignalingType.offer,
          fromPeerId: _localPeerId,
          toPeerId: _remotePeerId,
          sdp: sdp,
        ),
      );
    } catch (e) {
      debugPrint('Offer gönderilemedi: $e');
    }
  }

  /// İlk offer/answer kaybolursa bağlantı kurulana kadar offer'ı yineler.
  void _startOfferRetry() {
    _offerRetryTimer?.cancel();
    _offerAttempts = 0;
    _offerRetryTimer = Timer.periodic(_offerRetryInterval, (timer) {
      if (_disposed ||
          _remoteDescriptionSet ||
          _state == WebRtcConnectionState.connected ||
          _offerAttempts >= _maxOfferAttempts) {
        timer.cancel();
        return;
      }
      _offerAttempts++;
      unawaited(_sendOfferMessage());
    });
  }

  void _stopOfferRetry() {
    _offerRetryTimer?.cancel();
    _offerRetryTimer = null;
  }

  /// Alıcı tarafında answer kaybolursa bağlantı kurulana kadar yineler.
  void _startAnswerRetry() {
    if (_isInitiator) return;
    _answerRetryTimer?.cancel();
    _answerAttempts = 0;
    _answerRetryTimer = Timer.periodic(_offerRetryInterval, (timer) {
      if (_disposed ||
          _localAnswerSdp == null ||
          _state == WebRtcConnectionState.connected ||
          _answerAttempts >= _maxAnswerAttempts) {
        timer.cancel();
        return;
      }
      _answerAttempts++;
      unawaited(_sendAnswerMessage());
    });
  }

  void _stopAnswerRetry() {
    _answerRetryTimer?.cancel();
    _answerRetryTimer = null;
  }

  /// flutter_webrtc (özellikle Windows) bazen ICE/PC olaylarını kaçırır;
  /// periyodik olarak gerçek durumu okuyup UI ile eşitle.
  void _startConnectionSync() {
    _connectionSyncTimer?.cancel();
    _connectionSyncTimer = Timer.periodic(_connectionSyncInterval, (_) {
      unawaited(_syncConnectionStateFromPeer());
    });
  }

  void _stopConnectionSync() {
    _connectionSyncTimer?.cancel();
    _connectionSyncTimer = null;
  }

  Future<void> _syncConnectionStateFromPeer() async {
    if (_disposed) {
      _stopConnectionSync();
      return;
    }

    final channel = _dataChannel;
    if (channel?.state == RTCDataChannelState.RTCDataChannelOpen) {
      _stopOfferRetry();
      _stopAnswerRetry();
      if (_state != WebRtcConnectionState.connected) {
        _setState(WebRtcConnectionState.connected);
      }
      _stopConnectionSync();
      return;
    }

    final pc = _peerConnection;
    if (pc == null) return;

    try {
      final ice = await pc.getIceConnectionState();
      if (ice == RTCIceConnectionState.RTCIceConnectionStateConnected ||
          ice == RTCIceConnectionState.RTCIceConnectionStateCompleted) {
        _stopOfferRetry();
        _stopAnswerRetry();
        if (_state != WebRtcConnectionState.connected) {
          _setState(WebRtcConnectionState.connected);
        }
        _stopConnectionSync();
        return;
      }
      if (ice == RTCIceConnectionState.RTCIceConnectionStateFailed) {
        _setState(WebRtcConnectionState.failed);
        _stopConnectionSync();
        return;
      }

      final conn = await pc.getConnectionState();
      if (conn == RTCPeerConnectionState.RTCPeerConnectionStateConnected) {
        _stopOfferRetry();
        _stopAnswerRetry();
        if (_state != WebRtcConnectionState.connected) {
          _setState(WebRtcConnectionState.connected);
        }
        _stopConnectionSync();
        return;
      }
      if (conn == RTCPeerConnectionState.RTCPeerConnectionStateFailed) {
        _setState(WebRtcConnectionState.failed);
        _stopConnectionSync();
      }
    } catch (e) {
      debugPrint('Bağlantı durumu senkronize edilemedi: $e');
    }
  }

  void _attachDataChannel(RTCDataChannel channel) {
    _dataChannel = channel;
    channel.onMessage = (message) {
      if (_disposed || _incomingDataController.isClosed) return;
      _incomingDataController.add(message);
    };
    channel.onDataChannelState = (state) {
      if (_disposed) return;
      debugPrint('Data channel state: $state');
      switch (state) {
        case RTCDataChannelState.RTCDataChannelOpen:
          _stopOfferRetry();
          _stopAnswerRetry();
          _setState(WebRtcConnectionState.connected);
        case RTCDataChannelState.RTCDataChannelClosing:
        case RTCDataChannelState.RTCDataChannelClosed:
          if (_state == WebRtcConnectionState.connected) {
            _setState(WebRtcConnectionState.disconnected);
          }
        default:
          break;
      }
    };

    // Kanal, handler eklenmeden önce açılmış olabilir (özellikle alıcı taraf /
    // iOS). Bu durumda `onDataChannelState` "open" olayı bir daha gelmez ve
    // bağlantı hiç "connected" işaretlenmez — guest sonsuza dek "bağlanıyor"da
    // kalır. Mevcut durumu okuyup gerekiyorsa hemen connected'a geç.
    if (channel.state == RTCDataChannelState.RTCDataChannelOpen) {
      _stopOfferRetry();
      _stopAnswerRetry();
      _setState(WebRtcConnectionState.connected);
    }
  }

  Future<void> handleSignalingMessage(SignalingMessage message) async {
    final pc = _peerConnection;
    if (pc == null || _disposed) {
      if (!_disposed) _pendingSignalingMessages.add(message);
      return;
    }

    await _dispatchSignalingMessage(pc, message);
  }

  Future<void> _flushPendingSignalingMessages() async {
    if (_disposed || _pendingSignalingMessages.isEmpty) return;
    final pending = List<SignalingMessage>.from(_pendingSignalingMessages);
    _pendingSignalingMessages.clear();
    final pc = _peerConnection;
    if (pc == null) return;
    for (final message in pending) {
      await _dispatchSignalingMessage(pc, message);
    }
  }

  Future<void> _dispatchSignalingMessage(
    RTCPeerConnection pc,
    SignalingMessage message,
  ) async {
    switch (message.type) {
      case SignalingType.offer:
        await _handleOffer(pc, message);
      case SignalingType.answer:
        await _handleAnswer(pc, message);
      case SignalingType.iceCandidate:
        if (message.candidate == null) return;
        await _addCandidateSafe(
          RTCIceCandidate(
            message.candidate,
            message.sdpMid,
            message.sdpMLineIndex,
          ),
        );
      case SignalingType.peerJoined:
      case SignalingType.peerLeft:
        break;
    }
  }

  Future<void> _handleOffer(
    RTCPeerConnection pc,
    SignalingMessage message,
  ) async {
    if (message.sdp == null) return;

    // Aynı offer yeniden geldiyse (initiator yeniden gönderdi) sadece
    // mevcut answer'ı tekrar yolla — setRemoteDescription'ı tekrarlama.
    if (_lastRemoteOfferSdp == message.sdp) {
      if (_localAnswerSdp != null) {
        await _sendAnswerMessage();
        if (_state == WebRtcConnectionState.connecting) {
          _duplicateOfferWhileConnecting++;
          if (_duplicateOfferWhileConnecting >= 3) {
            _duplicateOfferWhileConnecting = 0;
            await _recreatePeerConnectionAsGuest();
            return;
          }
        }
      }
      return;
    }
    _duplicateOfferWhileConnecting = 0;

    try {
      await pc.setRemoteDescription(
        RTCSessionDescription(message.sdp, 'offer'),
      );
      _lastRemoteOfferSdp = message.sdp;
      _remoteDescriptionSet = true;
      await _flushPendingCandidates();

      final answer = await pc.createAnswer();
      await pc.setLocalDescription(answer);
      _localAnswerSdp = answer.sdp;
      await _sendAnswerMessage();
      _startAnswerRetry();
      await _flushPendingSignalingMessages();
    } catch (e) {
      debugPrint('Offer işlenemedi: $e');
    }
  }

  /// Alıcı tarafında offer yanıtı sıkıştığında peer connection'ı sıfırla.
  Future<void> _recreatePeerConnectionAsGuest() async {
    if (_disposed || _isInitiator) return;

    debugPrint(
      'Alıcı tarafı bağlantıda sıkıştı — peer connection yeniden kuruluyor.',
    );

    final pending = List<SignalingMessage>.from(_pendingSignalingMessages);
    final lastOffer = _lastRemoteOfferSdp;

    _stopOfferRetry();
    _stopAnswerRetry();
    _stopConnectionSync();

    _peerConnection?.onIceCandidate = null;
    _peerConnection?.onConnectionState = null;
    _peerConnection?.onIceConnectionState = null;
    _peerConnection?.onDataChannel = null;
    _dataChannel?.onMessage = null;
    _dataChannel?.onDataChannelState = null;
    await _dataChannel?.close();
    await _peerConnection?.close();
    _dataChannel = null;
    _peerConnection = null;

    _remoteDescriptionSet = false;
    _localAnswerSdp = null;
    _lastRemoteOfferSdp = null;
    _pendingCandidates.clear();
    _setState(WebRtcConnectionState.connecting);

    _peerConnection = await createPeerConnection({
      'iceServers': _iceServers,
      'sdpSemantics': 'unified-plan',
      'iceCandidatePoolSize': 4,
    });

    _peerConnection!.onIceCandidate = (candidate) async {
      if (candidate.candidate == null || _disposed) return;
      try {
        await _signaling.sendMessage(
          SignalingMessage(
            type: SignalingType.iceCandidate,
            fromPeerId: _localPeerId,
            toPeerId: _remotePeerId,
            candidate: candidate.candidate,
            sdpMid: candidate.sdpMid,
            sdpMLineIndex: candidate.sdpMLineIndex,
          ),
        );
      } catch (e) {
        debugPrint('ICE candidate gönderilemedi: $e');
      }
    };

    _peerConnection!.onConnectionState = (state) {
      if (_disposed) return;
      debugPrint('WebRTC connection state: $state');
      switch (state) {
        case RTCPeerConnectionState.RTCPeerConnectionStateConnected:
          _stopOfferRetry();
          _stopAnswerRetry();
          _setState(WebRtcConnectionState.connected);
        case RTCPeerConnectionState.RTCPeerConnectionStateFailed:
          _setState(WebRtcConnectionState.failed);
        case RTCPeerConnectionState.RTCPeerConnectionStateDisconnected:
        case RTCPeerConnectionState.RTCPeerConnectionStateClosed:
          _setState(WebRtcConnectionState.disconnected);
        default:
          break;
      }
    };

    _peerConnection!.onIceConnectionState = (state) {
      if (_disposed) return;
      debugPrint('ICE connection state: $state');
      switch (state) {
        case RTCIceConnectionState.RTCIceConnectionStateConnected:
        case RTCIceConnectionState.RTCIceConnectionStateCompleted:
          _stopOfferRetry();
          _stopAnswerRetry();
          if (_state != WebRtcConnectionState.connected) {
            _setState(WebRtcConnectionState.connected);
          }
        case RTCIceConnectionState.RTCIceConnectionStateFailed:
          _setState(WebRtcConnectionState.failed);
        case RTCIceConnectionState.RTCIceConnectionStateDisconnected:
          if (_state == WebRtcConnectionState.connected) {
            _setState(WebRtcConnectionState.disconnected);
          }
        default:
          break;
      }
    };

    _peerConnection!.onDataChannel = (channel) {
      _attachDataChannel(channel);
    };

    _startConnectionSync();

    if (lastOffer != null) {
      await _handleOffer(
        _peerConnection!,
        SignalingMessage(
          type: SignalingType.offer,
          fromPeerId: _remotePeerId,
          toPeerId: _localPeerId,
          sdp: lastOffer,
        ),
      );
    }

    for (final message in pending) {
      await _dispatchSignalingMessage(_peerConnection!, message);
    }
  }

  Future<void> _sendAnswerMessage() async {
    final sdp = _localAnswerSdp;
    if (sdp == null || _disposed) return;
    try {
      await _signaling.sendMessage(
        SignalingMessage(
          type: SignalingType.answer,
          fromPeerId: _localPeerId,
          toPeerId: _remotePeerId,
          sdp: sdp,
        ),
      );
    } catch (e) {
      debugPrint('Answer gönderilemedi: $e');
    }
  }

  Future<void> _handleAnswer(
    RTCPeerConnection pc,
    SignalingMessage message,
  ) async {
    if (message.sdp == null) return;
    // Yinelenen answer'ları yoksay — aksi halde "wrong state" hatası olur.
    if (_remoteDescriptionSet) return;

    try {
      await pc.setRemoteDescription(
        RTCSessionDescription(message.sdp, 'answer'),
      );
      _remoteDescriptionSet = true;
      _stopOfferRetry();
      _stopAnswerRetry();
      await _flushPendingCandidates();
    } catch (e) {
      debugPrint('Answer işlenemedi: $e');
    }
  }

  Future<void> _addCandidateSafe(RTCIceCandidate candidate) async {
    final pc = _peerConnection;
    if (pc == null) return;

    if (!_remoteDescriptionSet) {
      _pendingCandidates.add(candidate);
      return;
    }

    try {
      await pc.addCandidate(candidate);
    } catch (e) {
      debugPrint('ICE candidate eklenemedi: $e');
    }
  }

  Future<void> _flushPendingCandidates() async {
    final pc = _peerConnection;
    if (pc == null || _pendingCandidates.isEmpty) return;

    final pending = List<RTCIceCandidate>.from(_pendingCandidates);
    _pendingCandidates.clear();

    for (final candidate in pending) {
      try {
        await pc.addCandidate(candidate);
      } catch (e) {
        debugPrint('Bekleyen ICE candidate eklenemedi: $e');
      }
    }
  }

  Future<void> send(dynamic data) async {
    final channel = _dataChannel;
    if (channel == null ||
        channel.state != RTCDataChannelState.RTCDataChannelOpen) {
      throw StateError('Veri kanalı hazır değil.');
    }
    await channel.send(data);
  }

  bool get isDataChannelOpen =>
      _dataChannel?.state == RTCDataChannelState.RTCDataChannelOpen;

  void _setState(WebRtcConnectionState newState) {
    if (_disposed || _connectionStateController.isClosed) return;
    _state = newState;
    _connectionStateController.add(newState);
  }

  Future<void> dispose() async {
    if (_disposed) return;
    _disposed = true;

    _stopOfferRetry();
    _stopAnswerRetry();
    _stopConnectionSync();

    _peerConnection?.onIceCandidate = null;
    _peerConnection?.onConnectionState = null;
    _peerConnection?.onIceConnectionState = null;
    _peerConnection?.onDataChannel = null;
    _dataChannel?.onMessage = null;
    _dataChannel?.onDataChannelState = null;

    await _dataChannel?.close();
    await _peerConnection?.close();
    await _connectionStateController.close();
    await _incomingDataController.close();
    _dataChannel = null;
    _peerConnection = null;
    _pendingCandidates.clear();
  }
}
