// lib/dialer_screen.dart
import 'dart:convert';
import 'dart:async';
import 'dart:typed_data';
import 'dart:math';

import 'package:flutter/foundation.dart'; // For kIsWeb
import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:web_socket_channel/web_socket_channel.dart';
import 'package:flutter_webrtc/flutter_webrtc.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:pointycastle/export.dart' as pc; // Use prefix for clarity
import 'package:record/record.dart'; // <-- Use record plugin
import 'package:audioplayers/audioplayers.dart'; // Audio Playback

import 'bb84_simulator.dart'; // Your BB84 simulator file

// Define QKD State Enum
enum QkdState { idle, exchanging, failed, success }

// Constants
const int aesKeyLengthBytes = 32;
const int gcmNonceLengthBytes = 12;
const int gcmTagLengthBits = 128;
const int recordSampleRate = 16000; // Use consistent sample rate

class DialerScreen extends StatefulWidget {
  const DialerScreen({super.key});

  @override
  State<DialerScreen> createState() => _DialerScreenState();
}

class _DialerScreenState extends State<DialerScreen> with WidgetsBindingObserver {
  // State Variables
  String _enteredNumber = '';
  String _myId = 'Loading...';
  String _connectionStatus = 'Disconnected';
  String _callStatus = '';
  bool _isInCall = false;
  String? _remoteUserId;

  // Networking
  WebSocketChannel? _channel;
  final String _webSocketUrl = 'ws://ec2-18-212-33-85.compute-1.amazonaws.com:8080'; // <-- IMPORTANT: SET YOUR IP/DNS

  // WebRTC
  RTCPeerConnection? _peerConnection;
  RTCDataChannel? _dataChannel;
  MediaStream? _localStream;
  MediaStream? _remoteStream;
//   final RTCVideoRenderer _localRenderer = RTCVideoRenderer();
//   final RTCVideoRenderer _remoteRenderer = RTCVideoRenderer();

  final Map<String, dynamic> _rtcConfiguration = {
    'iceServers': [{'urls': 'stun:stun.l.google.com:19302'}],
  };

  // QKD
  QkdState _qkdState = QkdState.idle;
  BB84Simulator? _qkdSimulator;
  Uint8List? _sharedKey;

  // Audio Handling (Using record plugin)
  late AudioRecorder _audioRecorder; // Use record plugin's recorder
  StreamSubscription<RecordState>? _recordStateSubscription;
  StreamSubscription<Amplitude>? _amplitudeSubscription; // Optional amplitude monitoring
  StreamController<Uint8List>? _audioChunkStreamController; // Stream chunks to network
  StreamSubscription<Uint8List>? _audioChunkSubscription; // Listen to controller

  AudioPlayer? _audioPlayer;
  bool _isAudioInitialized = false;
  bool _isSpeakerphoneOn = false;
  bool _isPlayingAudio = false;
  bool _isRecording = false; // Track recording state

  @override
  void initState() {
    super.initState();
    _audioRecorder = AudioRecorder(); // Initialize the recorder instance
    WidgetsBinding.instance.addObserver(this);
    // _initRenderers();
    _initializeAudioPlayback(); // Init player early
    _setupRecorderListeners(); // Setup listeners for recorder state
    _loadOrGenerateMyId().then((_) {
      if (_myId != 'Loading...' && _myId.isNotEmpty) {
         _connectWebSocket();
      }
    });
  }

//    Future<void> _initRenderers() async {
//     await _localRenderer.initialize();
//     await _remoteRenderer.initialize();
//   }

   void _setupRecorderListeners() {
       // Listen to recording state
       _recordStateSubscription = _audioRecorder.onStateChanged().listen((recordState) {
          print("Recorder state: $recordState");
          setStateIfMounted(() { _isRecording = recordState == RecordState.record; });
       }, onError: (e) {
           print("Recorder state error: $e");
           setStateIfMounted(() { _isRecording = false; });
       });

       // Optional: Listen to amplitude
       // _amplitudeSubscription = _audioRecorder.onAmplitudeChanged(const Duration(milliseconds: 200)).listen((amp) {
       //    // print("Amplitude: ${amp.current} dBFS");
       // });
   }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    super.didChangeAppLifecycleState(state);
     if (state == AppLifecycleState.paused || state == AppLifecycleState.inactive || state == AppLifecycleState.detached || state == AppLifecycleState.hidden) {
        if (_isRecording) _stopMicStream();
        if (_isPlayingAudio) _stopAudioPlayer();
     }
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _channel?.sink.close();
    _closeWebRTCSession(notifyServer: false);
    // _localRenderer.dispose();
    // _remoteRenderer.dispose();
    // Dispose record plugin resources
    _recordStateSubscription?.cancel();
    _amplitudeSubscription?.cancel();
    _audioRecorder.dispose(); // Dispose the recorder
    // Dispose stream controller and subscription for chunks
    _audioChunkSubscription?.cancel();
    _audioChunkStreamController?.close();
    // Dispose audioplayers
    _audioPlayer?.dispose();
    super.dispose();
  }

  // --- App ID Management ---
  String _generateRandomId() { return List.generate(10, (_) => Random().nextInt(10)).join(); }
  Future<void> _loadOrGenerateMyId() async {
       final prefs = await SharedPreferences.getInstance();
      String? existingId = prefs.getString('myQuantumId');
      if (existingId == null || existingId.isEmpty) {
          existingId = _generateRandomId();
          await prefs.setString('myQuantumId', existingId);
      }
      if (mounted) {
          setState(() { _myId = existingId!; });
      }
  }

  // --- WebSocket Management ---
  void _connectWebSocket() {
      if (_channel != null && _channel!.closeCode == null) return;
      print('Connecting to $_webSocketUrl...');
      if (mounted) setState(() { _connectionStatus = 'Connecting...'; });
      try {
          _channel = WebSocketChannel.connect(Uri.parse(_webSocketUrl));
           if (mounted) setState(() { _connectionStatus = 'Connected (Registering...)'; });
          _sendMessage({'action': 'register', 'userId': _myId});
          _channel!.stream.listen(
              (dynamic message) { _handleServerMessage(message); },
              onDone: _handleWebSocketDone,
              onError: _handleWebSocketError,
              cancelOnError: true
          );
      } catch (e) { _handleWebSocketError(e); }
  }
  void _sendMessage(Map<String, dynamic> message) {
       if (_channel != null && _channel!.closeCode == null) { _channel!.sink.add(jsonEncode(message)); }
       else { /* ... Handle disconnected ... */ }
  }
  void _handleWebSocketDone() {
       print('WebSocket disconnected.');
        if (mounted) { setState(() { _connectionStatus = 'Disconnected'; _callStatus = 'Connection Lost'; if(_isInCall) _closeWebRTCSession(notifyServer: false); }); }
  }
   void _handleWebSocketError(dynamic error, [StackTrace? stackTrace]) {
       print('WebSocket error: $error');
       if (stackTrace != null) { print('Stack trace: $stackTrace'); }
        if (mounted) { setState(() { _connectionStatus = 'Error'; _callStatus = 'Connection Error'; if(_isInCall) _closeWebRTCSession(notifyServer: false); }); }
   }

  // --- Server Message Handler & Action Handlers ---
  void _handleServerMessage(dynamic message) {
     if(!mounted) return;
     if (message is String) {
         try {
             final decodedMessage = jsonDecode(message) as Map<String, dynamic>;
             final action = decodedMessage['action'];
             final fromId = decodedMessage['fromId'] ?? decodedMessage['relayedFrom'];
             switch (action) {
                 case 'registered': setState(() { _connectionStatus = 'Registered'; }); break;
                 case 'incomingCall': _handleIncomingCallAction(fromId); break;
                 case 'callStatus': _handleCallStatusAction(fromId, decodedMessage); break;
                 case 'qkdMessage': _handleQkdMessageAction(fromId, decodedMessage); break;
                 case 'webrtcSignal': _handleWebRTCSignalAction(fromId, decodedMessage); break;
                 case 'callEnded': _handleCallEndedAction(fromId); break;
                 case 'callError': _handleCallErrorAction(decodedMessage); break;
             }
         } catch (e) { print('Failed to decode or handle server message: $e'); }
     } else { print('Received non-string message from WebSocket: ${message.runtimeType}'); }
  }
  void _handleIncomingCallAction(String? fromId) {
       if (fromId == null || _isInCall) return;
       _remoteUserId = fromId; setState(() { _callStatus = 'Incoming call from $fromId'; }); _showIncomingCallDialog(fromId);
  }
  void _handleCallStatusAction(String? fromId, Map<String, dynamic> decodedMessage) {
        if (fromId == _remoteUserId) {
            final accepted = decodedMessage['accepted'] as bool?;
            if (accepted == true) { setState(() { _callStatus = 'Call accepted by $fromId. Starting QKD...'; }); _startQkdProcess(isInitiator: true);
            } else { setState(() { _callStatus = 'Call with $fromId rejected.'; }); _resetCallState(); }
        }
  }
  void _handleQkdMessageAction(String? fromId, Map<String, dynamic> decodedMessage) {
         if (fromId == _remoteUserId && _qkdSimulator != null && _qkdState == QkdState.exchanging && decodedMessage['data'] != null) { _qkdSimulator!.processSignal(decodedMessage['data']); }
  }
  void _handleWebRTCSignalAction(String? fromId, Map<String, dynamic> decodedMessage) {
         if (fromId == _remoteUserId && decodedMessage['data'] != null && _qkdState == QkdState.success) { _handleWebRTCSignal(decodedMessage['data']); }
  }
  void _handleCallEndedAction(String? fromId) {
          if (fromId == _remoteUserId) { setState(() { _callStatus = 'Call ended by $fromId.'; }); _closeWebRTCSession(notifyServer: false); }
  }
  void _handleCallErrorAction(Map<String, dynamic> decodedMessage) {
         setState(() { _callStatus = 'Call Error: ${decodedMessage['reason']}'; _resetCallState(); });
  }

  // --- Call Control UI ---
  Future<void> _showIncomingCallDialog(String fromId) async {
       return showDialog<void>( context: context, barrierDismissible: false, builder: (BuildContext context) {
          return AlertDialog( title: const Text('Incoming Call'), content: Text('Call from ID: $fromId'),
            actions: <Widget>[
              TextButton(child: const Text('Reject'), onPressed: () { Navigator.of(context).pop(); _sendCallResponse(fromId, false); setState(() { _callStatus = 'Rejected call from $fromId'; _remoteUserId = null;}); }),
              TextButton(child: const Text('Accept'), onPressed: () { Navigator.of(context).pop(); _sendCallResponse(fromId, true); setState(() { _callStatus = 'Accepted call from $fromId. Starting QKD...'; _isInCall = true; _remoteUserId = fromId; }); _startQkdProcess(isInitiator: false); }),
            ],
          );
       });
  }
   void _sendCallResponse(String originalCallerId, bool accepted) { _sendMessage({'action': 'callResponse', 'toId': originalCallerId, 'fromId': _myId, 'accepted': accepted }); }
   void _initiateSecureCall() {
        final String targetId = _enteredNumber;
       if (!_connectionStatus.startsWith('Registered')) { _connectWebSocket(); return; }
       if (_isInCall) { return; }
       if (targetId.isNotEmpty && targetId.length == 10) {
           if (targetId == _myId) { ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('Cannot call yourself.'))); return; }
           print('Requesting secure call from $_myId to target ID: $targetId');
           setState(() { _callStatus = 'Calling $targetId...'; _isInCall = true; _remoteUserId = targetId; });
           _sendMessage({'action': 'callRequest', 'toId': targetId, 'fromId': _myId});
       } else { ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('Please enter a valid 10-digit ID.'))); }
   }
   void _hangUp() {
        print("Hang Up initiated.");
      if (_remoteUserId != null && _channel != null && _channel!.closeCode == null) { _sendMessage({'action': 'hangUp', 'toId': _remoteUserId!, 'fromId': _myId}); }
     _closeWebRTCSession(notifyServer: false);
   }

  // --- QKD Process ---
  void _startQkdProcess({required bool isInitiator}) {
        if (_qkdState != QkdState.idle) return;
        print("Starting QKD Process as ${isInitiator ? 'Alice' : 'Bob'}");
        setState(() { _qkdState = QkdState.exchanging; _callStatus = "Exchanging quantum keys..."; _sharedKey = null; });
        _qkdSimulator = BB84Simulator( keyLength: 1024, isAlice: isInitiator, sendSignal: _sendQkdMessage, onKeyDerived: _handleKeyDerived);
        _qkdSimulator!.startExchange();
  }
  void _sendQkdMessage(Map<String, dynamic> qkdData) { if (_remoteUserId != null && _qkdState == QkdState.exchanging) { _sendMessage({'action': 'qkdMessage', 'toId': _remoteUserId!, 'fromId': _myId, 'data': qkdData }); } }
  void _handleKeyDerived(Uint8List? derivedKey) {
        if (!mounted || _qkdState != QkdState.exchanging) return;
       if (derivedKey != null && derivedKey.length >= BB84Simulator.minFinalKeyLengthBytes) {
           print("QKD SUCCESS! Derived key: ${derivedKey.length} bytes.");
           setState(() { _sharedKey = derivedKey; _qkdState = QkdState.success; _callStatus = "Key exchange complete. Connecting media..."; });
           _startWebRTCSession(isInitiator: _qkdSimulator?.isAlice ?? false);
       } else {
           print("QKD FAILED!");
           setState(() { _sharedKey = null; _qkdState = QkdState.failed; _callStatus = "Key exchange failed. Call aborted."; });
           _hangUp();
       }
       _qkdSimulator = null;
  }

  // --- WebRTC Session Setup ---
   Future<void> _startWebRTCSession({required bool isInitiator}) async {
        if (_qkdState != QkdState.success || _sharedKey == null) { _resetCallState(); return; }
        if (_peerConnection != null) { return; }
        print("Starting WebRTC session (using DataChannel for audio)");
        if (!await _requestPermissions()) { setStateIfMounted(() => _callStatus = "Permission Denied"); _resetCallState(); return; }
        if (!_isAudioInitialized) await _initializeAudioPlayback();

        try {
            _peerConnection = await createPeerConnection(_rtcConfiguration);
            if (_peerConnection == null) throw Exception("Failed to create Peer Connection");
             _peerConnection!.onIceCandidate = (candidate) { _sendWebRTCSignal({'type': 'candidate','candidate': candidate.toMap()}); };
             _peerConnection!.onConnectionState = (state) {
                  print('WebRTC Connection State changed: $state');
                  if (state == RTCPeerConnectionState.RTCPeerConnectionStateConnected && _isInCall) { setStateIfMounted(() { _callStatus = 'Securely Connected'; });
                  } else if ((state == RTCPeerConnectionState.RTCPeerConnectionStateDisconnected || state == RTCPeerConnectionState.RTCPeerConnectionStateFailed || state == RTCPeerConnectionState.RTCPeerConnectionStateClosed) && _isInCall) {
                     print("WebRTC connection lost or closed unexpectedly."); _closeWebRTCSession(notifyServer: false); setStateIfMounted(() { _callStatus = 'Call disconnected.'; });
                  }
             };
             _peerConnection!.onIceConnectionState = (state) { print('ICE Connection State changed: $state'); };
             _peerConnection!.onDataChannel = (channel) {
    print("Remote DataChannel received: ${channel.label}");
    // IMPORTANT: Decide if you NEED the remote channel reference.
    // If you only ever SEND on the channel YOU created (_dataChannel initialized earlier),
    // you might not need to reassign _dataChannel here.
    // If you DO need it (e.g., to check properties), assign it but DON'T attach mic-starting listeners.

    // Assign the remote channel reference if needed, but be careful not to overwrite
    // the one you use for sending if it's different. Maybe use a different variable?
    // RTCDataChannel _remoteDataChannel = channel; // Example

    // Set up LISTENING part for the remote channel
    channel.onMessage = (RTCDataChannelMessage message) {
       if (message.isBinary) {
          _handleEncryptedAudioData(message.binary);
       }
    };
    // Optionally listen for its closure if needed for cleanup logic
    channel.onDataChannelState = (state) {
        print("Remote DataChannel State: $state");
        if (state == RTCDataChannelState.RTCDataChannelClosed) {
            print("Remote DataChannel CLOSED!");
            // Maybe trigger some cleanup if the remote side explicitly closed it?
            // Be careful not to duplicate cleanup logic triggered by _peerConnection states.
        }
    };

    // DO NOT call _setupDataChannelListeners(channel) here,
    // as that would attempt to start the mic stream again.
 };

            RTCDataChannelInit dataChannelDict = RTCDataChannelInit();
            _dataChannel = await _peerConnection!.createDataChannel('audioChannel', dataChannelDict);
            _setupDataChannelListeners(_dataChannel!);

            if (isInitiator) { RTCSessionDescription offer = await _peerConnection!.createOffer(); await _peerConnection!.setLocalDescription(offer); _sendWebRTCSignal(offer.toMap()); }

        } catch (e) { print("Error starting WebRTC session: $e"); setStateIfMounted(() { _callStatus = "WebRTC Error"; }); _closeWebRTCSession(notifyServer: true); }
   }
   void _setupDataChannelListeners(RTCDataChannel channel) {
        channel.onDataChannelState = (state) {
           print("DataChannel State: $state");
           if (state == RTCDataChannelState.RTCDataChannelOpen) { print("DataChannel OPENED! Starting audio stream..."); _startMicStream(channel); }
           else if (state == RTCDataChannelState.RTCDataChannelClosed) { print("DataChannel CLOSED! Stopping audio stream..."); _stopMicStream(); }
       };
       channel.onMessage = (RTCDataChannelMessage message) { if (message.isBinary) { _handleEncryptedAudioData(message.binary); } };
   }
   Future<void> _handleWebRTCSignal(Map<String, dynamic> signal) async {
        if (_peerConnection == null) { return; }
         try {
             switch (signal['type']) {
                 case 'offer': await _peerConnection!.setRemoteDescription(RTCSessionDescription(signal['sdp'], signal['type'])); RTCSessionDescription answer = await _peerConnection!.createAnswer(); await _peerConnection!.setLocalDescription(answer); _sendWebRTCSignal(answer.toMap()); break;
                 case 'answer': await _peerConnection!.setRemoteDescription(RTCSessionDescription(signal['sdp'], signal['type'])); break;
                 case 'candidate': if (signal['candidate'] != null) { RTCIceCandidate candidate = RTCIceCandidate(signal['candidate']['candidate'], signal['candidate']['sdpMid'], signal['candidate']['sdpMLineIndex']); await _peerConnection!.addCandidate(candidate); } break;
             }
         } catch (e) { print("Error handling WebRTC signal (${signal['type']}): $e"); }
   }
   void _sendWebRTCSignal(Map<String, dynamic> data) { if (_remoteUserId != null) { _sendMessage({ 'action': 'webrtcSignal', 'toId': _remoteUserId!, 'fromId': _myId, 'data': data }); } }

   // --- Audio Capture (Using record), Encryption, Sending ---
   Future<void> _startMicStream(RTCDataChannel channel) async {
       if (_isRecording) { print("Already recording."); return; }
       if (!await _requestPermissions()) { print("Mic permission denied."); return; }

       // Cancel previous listener
       await _audioChunkSubscription?.cancel();
       _audioChunkSubscription = null;
       // Ensure previous controller is closed
       await _audioChunkStreamController?.close();
       _audioChunkStreamController = null;

       try {
           // Create a stream controller to get audio chunks
           _audioChunkStreamController = StreamController<Uint8List>();

           print("Starting 'record' plugin recorder...");
           // Start recording to the stream controller
           await _audioRecorder.startStream(const RecordConfig(
                encoder: AudioEncoder.pcm16bits, // Use PCM16
                sampleRate: recordSampleRate,
                numChannels: 1, // Mono
           ));

           // Listen to the stream controller
           _audioChunkSubscription = _audioChunkStreamController!.stream.listen(
               (audioChunk) {
                   // print("Audio chunk size: ${audioChunk.length}"); // Debug
                   if (_sharedKey != null && channel.state == RTCDataChannelState.RTCDataChannelOpen) {
                       Uint8List? encryptedData = _encryptAudioChunk(audioChunk);
                       if (encryptedData != null && _dataChannel?.state == RTCDataChannelState.RTCDataChannelOpen) {
                            try { channel.send(RTCDataChannelMessage.fromBinary(encryptedData)); }
                            catch (e) { print("Error sending data via channel: $e"); }
                       }
                   }
               },
               onError: (error) {
                   print("'record' stream error: $error");
                   _stopMicStream(); // Stop on error
               },
               onDone: () {
                   print("'record' stream closed.");
                   _stopMicStream();
               },
               cancelOnError: false // Keep listening even after errors? Maybe true better.
           );

           // The record plugin doesn't directly expose the stream,
           // so we need to handle it differently. Start recording without specifying a path.
           // This *should* trigger the state change listener if successful.
           // Check the `record` plugin documentation for the exact way to get raw stream data.
           // --- THIS PART NEEDS ADJUSTMENT BASED ON `record` API ---
           // If `startStream` requires a StreamConsumer, we might need to create one.
           // If it records to a file, this whole approach is wrong for real-time.
           // Assuming `startStream` populates a stream we can access,
           // OR if we must record to temp file and read chunks (inefficient).

           // *** Re-checking `record` documentation: `startStream` returns the stream directly! ***
            final stream = await _audioRecorder.startStream(const RecordConfig(
                encoder: AudioEncoder.pcm16bits,
                sampleRate: recordSampleRate,
                numChannels: 1,
           ));

            _audioChunkSubscription = stream.listen( (audioChunk) {
                 // print("Audio chunk size: ${audioChunk.length}"); // Debug
                 if (_sharedKey != null && channel.state == RTCDataChannelState.RTCDataChannelOpen) {
                     Uint8List? encryptedData = _encryptAudioChunk(audioChunk);
                     if (encryptedData != null && _dataChannel?.state == RTCDataChannelState.RTCDataChannelOpen) {
                          try { channel.send(RTCDataChannelMessage.fromBinary(encryptedData)); }
                          catch (e) { print("Error sending data via channel: $e"); }
                     }
                 }
              }, onError: (error) { print("'record' stream error: $error"); _stopMicStream(); },
                 onDone: () { print("'record' stream closed."); _stopMicStream(); }, cancelOnError: true );

           print("'record' plugin recording started.");
           // State listener (_audioRecorder.onStateChanged) should update _isRecording

       } catch (e) {
           print("Error starting 'record' recorder: $e");
           setStateIfMounted(() { _callStatus = "Mic Error"; });
           // Ensure cleanup if start fails
            await _audioChunkSubscription?.cancel(); _audioChunkSubscription = null;
            if (_isRecording) { await _audioRecorder.stop(); }
       }
   }

   Future<void> _stopMicStream() async {
       if (!_isRecording) return; // Check state managed by listener
       print("Stopping 'record' recorder...");
       try {
           // Stop recording
           await _audioRecorder.stop();
           // Cancel the stream listener
           await _audioChunkSubscription?.cancel();
           _audioChunkSubscription = null;
           // State listener should set _isRecording to false
       } catch (e) {
           print("Error stopping 'record' recorder: $e");
           // Manually reset state if needed
           if (mounted) setState(() => _isRecording = false);
       }
       // Ensure state is updated if listener didn't fire
       if (mounted && _isRecording) { setState(() => _isRecording = false); }
   }
   Uint8List? _encryptAudioChunk(Uint8List audioChunk) {
       if (_sharedKey == null || _sharedKey!.length != aesKeyLengthBytes) return null;
       try {
           final nonce = _generateSecureNonce();
           final cipher = pc.GCMBlockCipher(pc.AESFastEngine());
           final params = pc.AEADParameters(pc.KeyParameter(_sharedKey!), gcmTagLengthBits, nonce, Uint8List(0));
           cipher.init(true, params);
           Uint8List encryptedChunk = cipher.process(audioChunk);
           final combined = Uint8List(gcmNonceLengthBytes + encryptedChunk.length);
           combined.setRange(0, gcmNonceLengthBytes, nonce);
           combined.setRange(gcmNonceLengthBytes, combined.length, encryptedChunk);
           return combined;
       } catch (e) { print("Encryption failed: $e"); return null; }
   }
   Uint8List _generateSecureNonce() {
       final secureRandom = pc.FortunaRandom();
       final seedSource = Random.secure();
       final seeds = Uint8List.fromList(List.generate(32, (_) => seedSource.nextInt(256)));
       secureRandom.seed(pc.KeyParameter(seeds));
       return secureRandom.nextBytes(gcmNonceLengthBytes);
   }

  // --- Audio Receiving, Decryption, Playback ---
   Future<void> _initializeAudioPlayback() async {
       if (_audioPlayer != null) { return; }
       _audioPlayer = AudioPlayer();
       _audioPlayer!.setReleaseMode(ReleaseMode.stop);
       _audioPlayer!.onPlayerStateChanged.listen((state) { setStateIfMounted(() { _isPlayingAudio = (state == PlayerState.playing); }); }, onError: (msg) { print('AudioPlayer error: $msg'); setStateIfMounted(() { _isPlayingAudio = false; }); });
       _isAudioInitialized = true;
       print("Audio playback initialized.");
       await _setSpeakerphone(_isSpeakerphoneOn);
   }
   void _handleEncryptedAudioData(Uint8List encryptedData) {
       if (!_isAudioInitialized || _sharedKey == null || _audioPlayer == null) return;
       if (encryptedData.length <= gcmNonceLengthBytes) { return; }
       try {
           // Decrypt
           final nonce = encryptedData.sublist(0, gcmNonceLengthBytes);
           final ciphertext = encryptedData.sublist(gcmNonceLengthBytes);
           final cipher = pc.GCMBlockCipher(pc.AESFastEngine());
           final params = pc.AEADParameters(pc.KeyParameter(_sharedKey!), gcmTagLengthBits, nonce, Uint8List(0));
           cipher.init(false, params);
           Uint8List decryptedBytes = cipher.process(ciphertext);

           // Play if not busy
           if (_audioPlayer!.state != PlayerState.playing) {
               _audioPlayer!.play(BytesSource(decryptedBytes), mode: PlayerMode.lowLatency);
           } else { /* Optionally queue or drop */ }

       } catch (e) { print("Decryption failed: $e"); }
   }
   Future<void> _stopAudioPlayer() async {
       print("Stopping audio player...");
       if (_audioPlayer != null) {
           try { await _audioPlayer!.stop(); } catch (e) { print("Error stopping audio player: $e"); }
       }
       _isPlayingAudio = false;
   }
   Future<void> _setSpeakerphone(bool enable) async {
        if (kIsWeb || defaultTargetPlatform != TargetPlatform.android && defaultTargetPlatform != TargetPlatform.iOS) { return; }
        try { await Helper.setSpeakerphoneOn(enable); setStateIfMounted(() { _isSpeakerphoneOn = enable; }); }
        catch (e) { print("Failed to set speakerphone: $e"); }
   }
   void _toggleSpeakerphone() { _setSpeakerphone(!_isSpeakerphoneOn); }

  // --- Permission Handling ---
  Future<bool> _requestPermissions() async {
       // Use record plugin's permission check
       if (await _audioRecorder.hasPermission()) {
            return true;
       } else {
            print("Requesting microphone permission...");
            // Show rationale if needed before requesting
            // bool granted = await _audioRecorder.requestPermission(); // This might not exist, use permission_handler
             var statusMic = await Permission.microphone.request();
             if(statusMic.isGranted){
                return true;
             } else {
                print("Microphone permission denied.");
                return false;
             }
       }
  }

  // --- Cleanup Logic ---
  Future<void> _closeWebRTCSession({required bool notifyServer}) async {
     print("Closing WebRTC session and resetting state...");
     await _stopMicStream();
     await _stopAudioPlayer();
     try { await _dataChannel?.close(); } catch (e) { /* ... */ } _dataChannel = null;
     try { await _peerConnection?.close(); } catch (e) { /* ... */ } _peerConnection = null;
     try { await _localStream?.dispose(); } catch (e) { /* ... */ } _localStream = null;
     try { await _remoteStream?.dispose(); } catch (e) { /* ... */ } _remoteStream = null;
     _qkdSimulator?.reset(); _qkdSimulator = null;
     _resetCallState();
  }
   void _resetCallState() {
        _qkdSimulator = null;
        if(mounted) {
            setState(() {
                _isInCall = false;
                _remoteUserId = null;
                _qkdState = QkdState.idle;
                _sharedKey = null;
                if (!_callStatus.contains("Error") && !_callStatus.contains("disconnect")) { _callStatus = 'Ready'; }
            });
        }
   }
   void setStateIfMounted(VoidCallback fn) { if (mounted) { setState(fn); } }

   // --- Digit Handling Functions ---
   void _addDigit(String digit) {
       if (!_isInCall && _enteredNumber.length < 10) {
           setState(() { _enteredNumber += digit; });
       }
   }
   void _deleteDigit() {
       if (!_isInCall && _enteredNumber.isNotEmpty) {
           setState(() { _enteredNumber = _enteredNumber.substring(0, _enteredNumber.length - 1); });
       }
   }

  // --- Build UI ---
  @override
  Widget build(BuildContext context) {
       return Scaffold(
      appBar: AppBar( title: Text('My ID: $_myId'), centerTitle: true,
        actions: [ Padding( padding: const EdgeInsets.only(right: 8.0), child: Center(child: Text(_connectionStatus, style: const TextStyle(fontSize: 12))), ), IconButton( icon: const Icon(Icons.refresh), onPressed: () async { /* ID refresh */ }, tooltip: 'Generate New ID' ) ],
        leading: _connectionStatus != 'Disconnected' ? null : IconButton( icon: Icon(Icons.sync_problem), tooltip: 'Reconnect', onPressed: _connectWebSocket ),
      ),
      body: Column( children: <Widget>[ Container( padding: const EdgeInsets.symmetric(vertical: 10, horizontal: 20), color: Colors.blueGrey[100], width: double.infinity, child: Text( _callStatus.isEmpty ? 'Ready' : _callStatus, textAlign: TextAlign.center, style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 16) ) ), Expanded( child: _isInCall ? _buildInCallView() : _buildDialerView() ) ] ),
      floatingActionButton: _isInCall ? FloatingActionButton( onPressed: _hangUp, backgroundColor: Colors.red, tooltip: 'Hang Up', child: const Icon(Icons.call_end) ) : null,
    );
  }
  Widget _buildDialerView() {
      return Column( children: <Widget>[
           Expanded(flex: 2, child: Container( alignment: Alignment.center, padding: const EdgeInsets.all(20.0), child: Text( _enteredNumber.isEmpty ? 'Enter Target ID' : _enteredNumber, style: TextStyle(fontSize: 34.0, fontWeight: FontWeight.bold, color: _enteredNumber.isEmpty ? Colors.grey : Colors.black), textAlign: TextAlign.center ) )),
           Expanded(flex: 5, child: Padding( padding: const EdgeInsets.symmetric(horizontal: 20.0, vertical: 10.0), child: Column( mainAxisAlignment: MainAxisAlignment.spaceEvenly, children: [ _buildNumberRow(['1', '2', '3']), _buildNumberRow(['4', '5', '6']), _buildNumberRow(['7', '8', '9']), Row(mainAxisAlignment: MainAxisAlignment.spaceEvenly, children: <Widget>[ _buildEmptyButton(), _buildNumberButton('0'), _buildActionButton(icon: Icons.backspace_outlined, onPressed: _deleteDigit, color: Colors.orangeAccent) ]) ]))),
           Padding( padding: const EdgeInsets.fromLTRB(20.0, 10.0, 20.0, 20.0), child: SizedBox( width: double.infinity, height: 60, child: ElevatedButton.icon( icon: const Icon(Icons.phonelink_ring_outlined), label: const Text('Connect Securely'), style: ElevatedButton.styleFrom( backgroundColor: Colors.green, foregroundColor: Colors.white, textStyle: const TextStyle(fontSize: 20.0, fontWeight: FontWeight.bold), shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12))), onPressed: _initiateSecureCall ) ) ),
       ]);
  }
  Widget _buildInCallView() {
       return Center(
         child: Column(
           mainAxisAlignment: MainAxisAlignment.center,
           children: [ // <-- This bracket should NOT be commented out
             Text('Securely Connected To:', style: Theme.of(context).textTheme.titleMedium),
             const SizedBox(height: 8),
             Text(_remoteUserId ?? 'Unknown', style: Theme.of(context).textTheme.headlineMedium?.copyWith(fontWeight: FontWeight.bold)),
             const SizedBox(height: 40),

             // Speakerphone controls (keep these)
             if (!kIsWeb && (defaultTargetPlatform == TargetPlatform.android || defaultTargetPlatform == TargetPlatform.iOS))
                IconButton(
                  icon: Icon(_isSpeakerphoneOn ? Icons.volume_up : Icons.volume_down),
                  iconSize: 40,
                  tooltip: _isSpeakerphoneOn ? 'Turn Speaker Off' : 'Turn Speaker On',
                  onPressed: _toggleSpeakerphone
                ),
             if (!kIsWeb && (defaultTargetPlatform == TargetPlatform.android || defaultTargetPlatform == TargetPlatform.iOS))
                const SizedBox(height: 10),
             if (!kIsWeb && (defaultTargetPlatform == TargetPlatform.android || defaultTargetPlatform == TargetPlatform.iOS))
               Text(_isSpeakerphoneOn ? 'Speaker On' : 'Speaker Off'),

             // --- This is the line to comment out or remove entirely ---
             // SizedBox(height: 1, width: 1, child: RTCVideoView(_localRenderer, mirror: true)),
             // SizedBox(height: 1, width: 1, child: RTCVideoView(_remoteRenderer, mirror: false))
             // --- End of commented out video views ---

           ] // <-- This bracket marks the end of the Column's children
         ) // <-- This bracket marks the end of the Column
       ); // <-- This bracket marks the end of the Center widget
  }
  Widget _buildNumberRow(List<String> digits) { return Expanded(child: Row(mainAxisAlignment: MainAxisAlignment.spaceEvenly, children: digits.map((d) => _buildNumberButton(d)).toList())); }
  Widget _buildNumberButton(String digit) { return Expanded(child: Padding(padding: const EdgeInsets.all(6.0), child: ElevatedButton( onPressed: () => _addDigit(digit), style: ElevatedButton.styleFrom(padding: const EdgeInsets.all(15.0), shape: const CircleBorder(), backgroundColor: Colors.blueGrey[50], foregroundColor: Colors.black87, elevation: 2), child: Text(digit, style: const TextStyle(fontSize: 26.0, fontWeight: FontWeight.w600)) ) )); }
  Widget _buildActionButton({required IconData icon, required VoidCallback onPressed, Color? color}) { return Expanded(child: Padding(padding: const EdgeInsets.all(6.0), child: ElevatedButton( onPressed: onPressed, style: ElevatedButton.styleFrom(padding: const EdgeInsets.all(15.0), shape: const CircleBorder(), backgroundColor: color ?? Theme.of(context).colorScheme.secondary, foregroundColor: Colors.white, elevation: 2), child: Icon(icon, size: 28.0) ) )); }
  Widget _buildEmptyButton() { return const Expanded(child: SizedBox()); }


} // End of _DialerScreenState