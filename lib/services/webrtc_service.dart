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

  // Müzakere sağlamlığı için durum.
  String? _localOfferSdp;
  String? _localAnswerSdp;
  String? _lastRemoteOfferSdp;
  Timer? _offerRetryTimer;
  int _offerAttempts = 0;
  static const _maxOfferAttempts = 6;

  static const _iceServers = [
    {'urls': 'stun:stun.l.google.com:19302'},
    {'urls': 'stun:stun1.l.google.com:19302'},
    // NAT/firewall arkasındaki cihazlar için (Mac ↔ Windows).
    {
      'urls': 'turn:openrelay.metered.ca:80',
      'username': 'openrelayproject',
      'credential': 'openrelayproject',
    },
    {
      'urls': 'turn:openrelay.metered.ca:443',
      'username': 'openrelayproject',
      'credential': 'openrelayproject',
    },
    {
      'urls': 'turn:openrelay.metered.ca:443?transport=tcp',
      'username': 'openrelayproject',
      'credential': 'openrelayproject',
    },
  ];

  Future<void> initialize() async {
    _setState(WebRtcConnectionState.connecting);
    _remoteDescriptionSet = false;
    _pendingCandidates.clear();

    _peerConnection = await createPeerConnection({
      'iceServers': _iceServers,
      'sdpSemantics': 'unified-plan',
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

      // Karşı tarafın signaling dinleyicisini kurması için kısa bekleme.
      await Future<void>.delayed(const Duration(milliseconds: 250));
      await _createAndSendOffer();
      _startOfferRetry();
    }
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
    _offerRetryTimer = Timer.periodic(const Duration(seconds: 2), (timer) {
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
  }

  Future<void> handleSignalingMessage(SignalingMessage message) async {
    final pc = _peerConnection;
    if (pc == null || _disposed) return;

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
      }
      return;
    }

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
    } catch (e) {
      debugPrint('Offer işlenemedi: $e');
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

    _peerConnection?.onIceCandidate = null;
    _peerConnection?.onConnectionState = null;
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
