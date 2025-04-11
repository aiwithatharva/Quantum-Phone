// lib/dialer_screen.dart
import 'dart:convert';
import 'dart:async';
import 'dart:typed_data';
import 'dart:math';
import 'dart:collection'; // Needed for Queue
import 'package:flutter/foundation.dart'; // For kIsWeb
import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:web_socket_channel/web_socket_channel.dart';
import 'package:flutter_webrtc/flutter_webrtc.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:pointycastle/export.dart' as pc;
import 'package:record/record.dart';
import 'package:audioplayers/audioplayers.dart';
import 'dart:io';
import 'bb84_simulator.dart';

// Define QKD State Enum
enum QkdState { idle, exchanging, failed, success }

// Constants
const int aesKeyLengthBytes = 32;
const int gcmNonceLengthBytes = 12;
const int gcmTagLengthBits = 128;
const int recordSampleRate = 16000;

// --- FIX 1: Moved Helper class outside ---
// Placeholder for Helper. Needs actual implementation or removal if not used.
class Helper {
  static Future<void> setSpeakerphoneOn(bool on) async {
    print(
        "---- WARNING: Helper.setSpeakerphoneOn called, but this is a placeholder. Implement native calls if needed. ----");
    // TODO: Implement platform channel calls to native code if speakerphone needed
    await Future.delayed(Duration(milliseconds: 50)); // Simulate async work
  }
}
// --- End FIX 1 ---

class DialerScreen extends StatefulWidget {
  const DialerScreen({super.key});

  @override
  State<DialerScreen> createState() => _DialerScreenState();
}

class _DialerScreenState extends State<DialerScreen> with WidgetsBindingObserver {
  // State Variables
  List<Map<String, dynamic>> _queuedWebRTCSignals = [];
  String _enteredNumber = '';
  String _myId = 'Loading...';
  String _connectionStatus = 'Disconnected';
  String _callStatus = '';
  bool _isInCall = false;
  String? _remoteUserId;

  // Networking
  WebSocketChannel? _channel;
  final String _webSocketUrl = 'ws://ec2-18-212-33-85.compute-1.amazonaws.com:8080';

  // WebRTC
  RTCPeerConnection? _peerConnection;
  RTCDataChannel? _dataChannel;
  RTCDataChannel? _remoteDataChannel;
  MediaStream? _localStream;
  MediaStream? _remoteStream;

  final Map<String, dynamic> _rtcConfiguration = {
    'iceServers': [
      {'urls': 'stun:stun.l.google.com:19302'},
      {'urls': 'stun:stun1.l.google.com:19302'},
      {'urls': 'stun:stun2.l.google.com:19302'},
    ],
    'sdpSemantics': 'unified-plan',
  };

  // QKD
  QkdState _qkdState = QkdState.idle;
  BB84Simulator? _qkdSimulator;
  Uint8List? _sharedKey;

  // Audio Handling (Using record plugin)
  late AudioRecorder _audioRecorder;
  StreamSubscription<RecordState>? _recordStateSubscription;
  StreamSubscription<Amplitude>? _amplitudeSubscription;
  StreamSubscription<Uint8List>? _audioChunkSubscription;

  // Audio Playback
  AudioPlayer? _audioPlayer;
  StreamSubscription? _playerCompleteSubscription; // For player completion
  StreamSubscription? _playerStateSubscription; // For player state
  bool _isAudioInitialized = false;
  bool _isSpeakerphoneOn = false;
  bool _isPlayingAudio = false;
  // --- ADD THESE LINES ---
  final Queue<Uint8List> _audioBuffer = Queue<Uint8List>();
  bool _isProcessingBuffer = false; // To prevent concurrent processing starts
  // --- END OF ADDED LINES ---
  bool _isRecording = false;
  Timer? _audioRecoveryTimer;



// --- ADD THIS NEW FUNCTION ---
// Place it somewhere logical, e.g., after _initializeAudioPlayback or _handleEncryptedAudioData
// Place this function inside the _DialerScreenState class

Uint8List _addWavHeader(Uint8List pcmData) {
  const int numChannels = 1;
  const int sampleRate = recordSampleRate; // Use your constant
  const int bitsPerSample = 16;
  const int byteRate = sampleRate * numChannels * bitsPerSample ~/ 8;
  const int blockAlign = numChannels * bitsPerSample ~/ 8;

  final int pcmDataLength = pcmData.length;
  final int fileSize = pcmDataLength + 44; // 44 bytes for the header

  final ByteData header = ByteData(44);

  // RIFF chunk descriptor
  header.setUint8(0, 0x52); // 'R'
  header.setUint8(1, 0x49); // 'I'
  header.setUint8(2, 0x46); // 'F'
  header.setUint8(3, 0x46); // 'F'
  header.setUint32(4, fileSize - 8, Endian.little); // ChunkSize
  header.setUint8(8, 0x57); // 'W'
  header.setUint8(9, 0x41); // 'A'
  header.setUint8(10, 0x56); // 'V'
  header.setUint8(11, 0x45); // 'E'

  // fmt sub-chunk
  header.setUint8(12, 0x66); // 'f'
  header.setUint8(13, 0x6D); // 'm'
  header.setUint8(14, 0x74); // 't'
  header.setUint8(15, 0x20); // ' '
  header.setUint32(16, 16, Endian.little); // Subchunk1Size (16 for PCM)
  header.setUint16(20, 1, Endian.little); // AudioFormat (1 for PCM)
  header.setUint16(22, numChannels, Endian.little); // NumChannels
  header.setUint32(24, sampleRate, Endian.little); // SampleRate
  header.setUint32(28, byteRate, Endian.little); // ByteRate
  header.setUint16(32, blockAlign, Endian.little); // BlockAlign
  header.setUint16(34, bitsPerSample, Endian.little); // BitsPerSample

  // data sub-chunk
  header.setUint8(36, 0x64); // 'd'
  header.setUint8(37, 0x61); // 'a'
  header.setUint8(38, 0x74); // 't'
  header.setUint8(39, 0x61); // 'a'
  header.setUint32(40, pcmDataLength, Endian.little); // Subchunk2Size

  // Combine header and PCM data
  final Uint8List wavData = Uint8List(fileSize);
  wavData.setRange(0, 44, header.buffer.asUint8List());
  wavData.setRange(44, fileSize, pcmData);

  return wavData;
}

// --- Revised _playNextChunkFromBuffer ---
Future<void> _playNextChunkFromBuffer() async {
  // Prevent concurrent starts IF ALREADY PROCESSING
  // Use a local variable check first for minor efficiency gain
  if (_isProcessingBuffer) {
     // print(">>>> Playback attempt skipped: Already processing another chunk.");
     return;
  }

  // Check if okay to proceed (buffer has data, player ready)
  if (_audioBuffer.isEmpty || _audioPlayer == null || !_isAudioInitialized) {
    // print(">>>> Playback skipped: Buffer empty or player not ready.");
    // Ensure processing flag is false if we decided not to play.
    if (mounted && _isProcessingBuffer) {
        // print(">>>> Sanity check: Resetting processing flag as buffer is empty/player not ready.");
        // This case shouldn't happen if entry condition `!_isProcessingBuffer` is met, but for safety:
        setStateIfMounted(() => _isProcessingBuffer = false);
    }
    return;
  }

  // --- Set flag: we are NOW starting to process a chunk ---
  // This state change MUST happen before any `await`
  setStateIfMounted(() => _isProcessingBuffer = true);
  // print(">>>> Starting to process next chunk. Setting processing flag to true. Buffer size: ${_audioBuffer.length}");

  try {
    final nextPcmChunk = _audioBuffer.removeFirst();
    if (nextPcmChunk.isEmpty) {
      print(">>>> Skipping empty chunk from buffer.");
      // Reset flag *immediately* since we didn't play anything.
      setStateIfMounted(() => _isProcessingBuffer = false);
      // Try the *next* one without waiting for onComplete
      // Use a microtask to avoid deep recursion issues if many empty chunks exist
      Future.microtask(_playNextChunkFromBuffer);
      return;
    }

    final wavChunk = _addWavHeader(nextPcmChunk);
    // print(">>>> Playing next chunk (PCM: ${nextPcmChunk.length}, WAV: ${wavChunk.length} bytes). Buffer size now: ${_audioBuffer.length}");
    // print(">>>> Calling _audioPlayer.play(BytesSource)...");

    await _audioPlayer!.play(BytesSource(wavChunk));
    // print(">>>> _audioPlayer.play() call completed. isProcessing should be TRUE. Waiting for onComplete or onError...");
    // Playback initiated. onPlayerComplete or onError will fire next and handle resetting the flag.
    // *** DO NOT reset the flag here ***

  } catch (e, s) {
    print("!!!! Error playing next chunk from buffer: $e");
    print("!!!! Stack trace: $s");
    _audioBuffer.clear(); // Clear buffer on playback error
    // Reset flag on error
    setStateIfMounted(() => _isProcessingBuffer = false);
  }
}


  @override
  void initState() {
    super.initState();
    _audioRecorder = AudioRecorder();
    WidgetsBinding.instance.addObserver(this);
    _initializeAudioPlayback();
    _setupRecorderListeners();
    _loadOrGenerateMyId().then((_) {
      if (_myId != 'Loading...' && _myId.isNotEmpty) {
        _connectWebSocket();
      }
    });
    print(">>>> DialerScreen initState completed.");
  }

  void _setupRecorderListeners() {
    _recordStateSubscription = _audioRecorder.onStateChanged().listen((recordState) {
      print(">>>> Recorder state changed: $recordState");
      setStateIfMounted(() {
        _isRecording = recordState == RecordState.record;
      });
      if (recordState == RecordState.stop && mounted) {
        print(">>>> Recorder stopped, ensuring _isRecording is false.");
        setStateIfMounted(() {
          _isRecording = false;
        });
      }
    }, onError: (e) {
      print("!!!! Recorder state error: $e");
      setStateIfMounted(() {
        _isRecording = false;
      });
    });
    print(">>>> Recorder listeners set up.");
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    super.didChangeAppLifecycleState(state);
    print(">>>> AppLifecycleState changed: $state");
    if (state == AppLifecycleState.paused ||
        state == AppLifecycleState.inactive ||
        state == AppLifecycleState.detached ||
        state == AppLifecycleState.hidden) {
      print(
          ">>>> App paused/inactive/detached/hidden. Stopping media streams if active.");
      if (_isRecording) _stopMicStream();
      if (_isPlayingAudio) _stopAudioPlayer();
    }
  }

  @override
  void dispose() {
    print(">>>> DialerScreen disposing...");
    WidgetsBinding.instance.removeObserver(this);
    _channel?.sink.close(1000, "Client disposed");
    _closeWebRTCSession(notifyServer: false);
    _audioRecoveryTimer?.cancel();
    _recordStateSubscription?.cancel();
    _amplitudeSubscription?.cancel();
    _audioRecorder.dispose();
    _audioChunkSubscription?.cancel();

    _playerCompleteSubscription?.cancel(); // Cancel player listener
    _playerStateSubscription?.cancel();   // Cancel player listener
    _audioPlayer?.dispose();
    _audioPlayer = null;

    print(">>>> DialerScreen disposed.");
    super.dispose();
  }

  // --- App ID Management ---
  String _generateRandomId() {
    return List.generate(10, (_) => Random().nextInt(10)).join();
  }

  Future<void> _loadOrGenerateMyId() async {
    final prefs = await SharedPreferences.getInstance();
    String? existingId = prefs.getString('myQuantumId');
    if (existingId == null || existingId.isEmpty) {
      existingId = _generateRandomId();
      await prefs.setString('myQuantumId', existingId);
      print(">>>> Generated new ID: $existingId");
    } else {
      print(">>>> Loaded existing ID: $existingId");
    }
    if (mounted) {
      setState(() {
        _myId = existingId!;
      });
    }
  }

  // --- WebSocket Management ---
  void _connectWebSocket() {
    if (_channel != null && _channel!.closeCode == null) {
      print(">>>> WebSocket already connecting/connected.");
      return;
    }
    print(">>>> Connecting to WebSocket: $_webSocketUrl...");
    if (mounted)
      setState(() {
        _connectionStatus = 'Connecting...';
      });
    try {
      _channel = WebSocketChannel.connect(Uri.parse(_webSocketUrl));
      print(">>>> WebSocket channel created. Setting up listeners...");
      if (mounted)
        setState(() {
          _connectionStatus = 'Connected (Registering...)';
        });

      _sendMessage({'action': 'register', 'userId': _myId});

      _channel!.stream.listen((dynamic message) {
        // print(">>>> WebSocket received message (raw): $message");
        _handleServerMessage(message);
      },
          onDone: _handleWebSocketDone,
          onError: _handleWebSocketError,
          cancelOnError: true);
    } catch (e, s) {
      print("!!!! WebSocket connection exception: $e");
      print("!!!! Stack trace: $s");
      _handleWebSocketError(e);
    }
  }

  void _sendMessage(Map<String, dynamic> message) {
    if (_channel != null && _channel!.closeCode == null) {
      final jsonMessage = jsonEncode(message);
      print(
          ">>>> WebSocket sending: Action: ${message['action']}, To: ${message['toId'] ?? 'N/A'}");
      if (message['action'] != 'webrtcSignal' &&
          message['action'] != 'qkdMessage') {
        print(">>>> WebSocket sending full message: $jsonMessage");
      } else if (message['action'] == 'webrtcSignal') {
        print(
            ">>>> WebSocket sending WebRTC Signal: Type: ${message['data']?['type'] ?? 'Unknown'}");
      } else if (message['action'] == 'qkdMessage') {
        print(
            ">>>> WebSocket sending QKD Signal: Type: ${message['data']?['type'] ?? 'Unknown'}");
      }
      _channel!.sink.add(jsonMessage);
    } else {
      print(
          "!!!! WebSocket cannot send message: Channel is null or closed. Status: ${_connectionStatus}, Close Code: ${_channel?.closeCode}");
      if (_connectionStatus != 'Connecting...') {
        setStateIfMounted(() {
          _connectionStatus = 'Error (Send Failed)';
          _callStatus = 'Connection Error';
        });
      }
    }
  }

  void _handleWebSocketDone() {
    print(
        "!!!! WebSocket disconnected (onDone). Close code: ${_channel?.closeCode}, Reason: ${_channel?.closeReason}");
    if (mounted) {
      setState(() {
        _connectionStatus = 'Disconnected';
        _callStatus = 'Connection Lost';
      });
      if (_isInCall) {
        print(">>>> WebSocket disconnected during call, closing WebRTC session.");
        _closeWebRTCSession(notifyServer: false);
      }
    }
    _channel = null;
  }

  void _handleWebSocketError(dynamic error, [StackTrace? stackTrace]) {
    print('!!!! WebSocket error: $error');
    if (stackTrace != null) {
      print('!!!! Stack trace: $stackTrace');
    }
    if (mounted) {
      setState(() {
        _connectionStatus = 'Error';
        _callStatus = 'Connection Error';
      });
      if (_isInCall) {
        print(">>>> WebSocket error during call, closing WebRTC session.");
        _closeWebRTCSession(notifyServer: false);
      }
    }
    _channel?.sink.close(1011, "WebSocket Error");
    _channel = null;
  }

  // --- Server Message Handler & Action Handlers ---
  void _handleServerMessage(dynamic message) {
    if (!mounted) {
      print("!!!! Received server message but widget is not mounted. Ignoring.");
      return;
    }
    if (message is String) {
      try {
        final decodedMessage = jsonDecode(message) as Map<String, dynamic>;
        final action = decodedMessage['action'] as String?;
        final fromId = decodedMessage['fromId'] as String? ??
            decodedMessage['relayedFrom'] as String?;
        final data = decodedMessage['data'];

        print(">>>> Handling server message: Action: $action, From: $fromId");

        switch (action) {
          case 'registered':
            print(">>>> Successfully registered with ID: ${_myId}");
            setState(() {
              _connectionStatus = 'Registered';
            });
            break;
          case 'incomingCall':
            _handleIncomingCallAction(fromId);
            break;
          case 'callStatus':
            _handleCallStatusAction(fromId, decodedMessage);
            break;
          case 'qkdMessage':
            if (data is Map<String, dynamic>) {
              _handleQkdMessageAction(fromId, data);
            } else {
              print(
                  "!!!! Invalid QKD message data format: Expected Map<String, dynamic>, got ${data?.runtimeType}");
            }
            break;
          case 'webrtcSignal':
            print(
                ">>>> Received WebRTC Signal Wrapper: From: $fromId, Data Type: ${data?.runtimeType}");
            if (data is Map<String, dynamic>) {
              _handleWebRTCSignalAction(fromId, data);
            } else {
              print(
                  "!!!! Invalid WebRTC signal data format: Expected Map<String, dynamic>, got ${data?.runtimeType}");
            }
            break;
          case 'callEnded':
            _handleCallEndedAction(fromId);
            break;
          case 'callError':
            _handleCallErrorAction(decodedMessage);
            break;
          default:
            print(">>>> Received unknown WebSocket action: $action");
        }
      } catch (e, s) {
        print('!!!! Failed to decode or handle server message: $e');
        print('!!!! Message content: $message');
        print('!!!! Stack trace: $s');
      }
    } else {
      print(
          '!!!! Received non-string message from WebSocket: ${message.runtimeType}');
    }
  }

  void _handleIncomingCallAction(String? fromId) {
    if (fromId == null) {
      print("!!!! Incoming call with null fromId.");
      return;
    }
    if (_isInCall) {
      print(
          "!!!! Ignoring incoming call from $fromId while already in a call with $_remoteUserId.");
      _sendCallResponse(fromId, false);
      return;
    }

    print(">>>> Handling incoming call from $fromId");
    _remoteUserId = fromId;
    setStateIfMounted(() {
      _callStatus = 'Incoming call from $fromId';
    });
    _showIncomingCallDialog(fromId);
  }

  void _handleCallStatusAction(
      String? fromId, Map<String, dynamic> decodedMessage) {
    final accepted = decodedMessage['accepted'] as bool?;
    print(">>>> Handling call status from $fromId: Accepted: $accepted");
    if (fromId == _remoteUserId) {
      if (accepted == true) {
        setStateIfMounted(() {
          _callStatus = 'Call accepted by $fromId. Starting QKD...';
        });
        _startQkdProcess(isInitiator: true);
      } else {
        setStateIfMounted(() {
          _callStatus = 'Call with $fromId rejected.';
        });
        _resetCallState();
      }
    } else {
      print(
          "!!!! Received call status for an unexpected remote user: $fromId (current: $_remoteUserId)");
    }
  }

  void _handleQkdMessageAction(String? fromId, Map<String, dynamic> qkdData) {
    print(">>>> Handling QKD message from $fromId. Current state: $_qkdState");
    if (fromId == _remoteUserId &&
        _qkdSimulator != null &&
        _qkdState == QkdState.exchanging) {
      print(">>>> Passing QKD data to simulator: Type: ${qkdData['type']}");
      _qkdSimulator!.processSignal(qkdData);
    } else {
      print(
          "!!!! Ignoring QKD message: ID mismatch ($fromId vs $_remoteUserId), null simulator, or wrong state ($_qkdState).");
    }
  }

  void _handleWebRTCSignalAction(
      String? fromId, Map<String, dynamic> webrtcData) {
    print(">>>> Handling WebRTC signal from $fromId. QKD State: $_qkdState");
    if (fromId == _remoteUserId && _qkdState == QkdState.success) {
      _handleWebRTCSignal(webrtcData);
    } else {
      print(
          "!!!! Ignoring WebRTC signal: ID mismatch ($fromId vs $_remoteUserId) or QKD not successful ($_qkdState).");
    }
  }

  void _handleCallEndedAction(String? fromId) {
    print(">>>> Handling call ended message from $fromId.");
    if (fromId == _remoteUserId) {
      setStateIfMounted(() {
        _callStatus = 'Call ended by $fromId.';
      });
      _closeWebRTCSession(notifyServer: false);
    } else {
      print(
          "!!!! Received call ended message for unexpected remote user: $fromId (current: $_remoteUserId)");
    }
  }

  void _handleCallErrorAction(Map<String, dynamic> decodedMessage) {
    final reason = decodedMessage['reason'] ?? 'Unknown error';
    print("!!!! Handling call error message: $reason");
    setStateIfMounted(() {
      _callStatus = 'Call Error: $reason';
    });
    _resetCallState();
  }

  // --- Call Control UI ---
  Future<void> _showIncomingCallDialog(String fromId) async {
    print(">>>> Showing incoming call dialog for $fromId");
    return showDialog<void>(
        context: context,
        barrierDismissible: false,
        builder: (BuildContext context) {
          return AlertDialog(
            title: const Text('Incoming Call'),
            content: Text('Call from ID: $fromId'),
            actions: <Widget>[
              TextButton(
                  child: const Text('Reject'),
                  onPressed: () {
                    print(">>>> Incoming call rejected by user.");
                    Navigator.of(context).pop();
                    _sendCallResponse(fromId, false);
                    setStateIfMounted(() {
                      _callStatus = 'Rejected call from $fromId';
                      _remoteUserId = null;
                    });
                  }),
              TextButton(
                  child: const Text('Accept'),
                  onPressed: () {
                    print(">>>> Incoming call accepted by user.");
                    Navigator.of(context).pop();
                    _sendCallResponse(fromId, true);
                    setStateIfMounted(() {
                      _callStatus =
                          'Accepted call from $fromId. Starting QKD...';
                      _isInCall = true;
                      _remoteUserId = fromId;
                    });
                    _startQkdProcess(isInitiator: false);
                  }),
            ],
          );
        });
  }

  void _sendCallResponse(String originalCallerId, bool accepted) {
    print(
        ">>>> Sending call response to $originalCallerId: Accepted: $accepted");
    _sendMessage({
      'action': 'callResponse',
      'toId': originalCallerId,
      'fromId': _myId,
      'accepted': accepted
    });
  }

  void _initiateSecureCall() {
    final String targetId = _enteredNumber;
    print(">>>> Initiate secure call button pressed. Target: $targetId");

    if (!_connectionStatus.startsWith('Registered')) {
      print("!!!! Cannot initiate call: Not registered. Attempting reconnect...");
      ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Not connected. Trying to reconnect...')));
      _connectWebSocket();
      return;
    }
    if (_isInCall) {
      print("!!!! Cannot initiate call: Already in call with $_remoteUserId.");
      ScaffoldMessenger.of(context)
          .showSnackBar(const SnackBar(content: Text('Already in a call.')));
      return;
    }
    if (targetId.isNotEmpty && targetId.length == 10) {
      if (targetId == _myId) {
        print("!!!! Cannot call self.");
        ScaffoldMessenger.of(context)
            .showSnackBar(const SnackBar(content: Text('Cannot call yourself.')));
        return;
      }
      print(">>>> Requesting secure call from $_myId to target ID: $targetId");
      setStateIfMounted(() {
        _callStatus = 'Calling $targetId...';
        _isInCall = true;
        _remoteUserId = targetId;
      });
      _sendMessage(
          {'action': 'callRequest', 'toId': targetId, 'fromId': _myId});
    } else {
      ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Please enter a valid 10-digit ID.')));
    }
  }

  void _hangUp() {
    print(">>>> Hang Up button pressed or initiated internally.");
    if (_remoteUserId != null && _channel != null && _channel!.closeCode == null) {
      print(">>>> Sending hangUp message to $_remoteUserId");
      _sendMessage(
          {'action': 'hangUp', 'toId': _remoteUserId!, 'fromId': _myId});
    } else {
      print(
          ">>>> Cannot send hangUp message (no remote user or WebSocket disconnected).");
    }
    _closeWebRTCSession(notifyServer: false);
  }

  // --- QKD Process ---
  void _startQkdProcess({required bool isInitiator}) {
    if (_qkdState != QkdState.idle) {
      print(
          "!!!! QKD process already started or not idle ($_qkdState). Ignoring request.");
      return;
    }
    print(">>>> Starting QKD Process (Role: ${isInitiator ? 'Alice' : 'Bob'})");
    setStateIfMounted(() {
      _qkdState = QkdState.exchanging;
      _callStatus = "Exchanging quantum keys...";
      _sharedKey = null;
    });
    _qkdSimulator = BB84Simulator(
      keyLength: 2048,
      isAlice: isInitiator,
      sendSignal: _sendQkdMessage,
      onKeyDerived: _handleKeyDerived,
    );
    _qkdSimulator!.startExchange();
  }

  void _sendQkdMessage(Map<String, dynamic> qkdData) {
    if (_remoteUserId != null && _qkdState == QkdState.exchanging) {
      print(
          ">>>> Sending QKD message (Type: ${qkdData['type']}) to $_remoteUserId");
      _sendMessage({
        'action': 'qkdMessage',
        'toId': _remoteUserId!,
        'fromId': _myId,
        'data': qkdData
      });
    } else {
      print(
          "!!!! Cannot send QKD message: No remote user or not in exchanging state ($_qkdState).");
    }
  }

  void _handleKeyDerived(Uint8List? derivedKey) {
    print(">>>> QKD Simulator finished. Result received.");
    if (!mounted || _qkdState != QkdState.exchanging) {
      print(
          "!!!! Ignoring QKD result: Widget not mounted or state is not 'exchanging' ($_qkdState).");
      return;
    }
    if (derivedKey != null &&
        derivedKey.length >= BB84Simulator.minFinalKeyLengthBytes) {
      print(">>>> QKD SUCCESS! Derived key length: ${derivedKey.length} bytes.");
      setStateIfMounted(() {
        _sharedKey = derivedKey;
        _qkdState = QkdState.success;
        _callStatus = "Key exchange complete. Connecting media...";
      });
      print(">>>> Proceeding to start WebRTC session...");
      _startWebRTCSession(isInitiator: _qkdSimulator?.isAlice ?? false);
    } else {
      print(
          "!!!! QKD FAILED! Derived key is null or too short (${derivedKey?.length ?? 'null'} bytes).");
      setStateIfMounted(() {
        _sharedKey = null;
        _qkdState = QkdState.failed;
        _callStatus = "Key exchange failed. Call aborted.";
      });
      _hangUp();
    }
    _qkdSimulator = null;
  }

  // --- WebRTC Session Setup ---
  Future<void> _startWebRTCSession({required bool isInitiator}) async {
    print(">>>> Entering _startWebRTCSession (Initiator: $isInitiator)");
    if (_qkdState != QkdState.success || _sharedKey == null) {
      print("!!!! Cannot start WebRTC: QKD not successful or key is null.");
      _resetCallState();
      return;
    }
    if (_peerConnection != null) {
      print("!!!! Cannot start WebRTC: PeerConnection already exists.");
      return;
    }

    print(">>>> Requesting permissions for WebRTC...");
    if (!await _requestPermissions()) {
      print("!!!! Permission denied for WebRTC.");
      setStateIfMounted(() => _callStatus = "Microphone Permission Denied");
      _resetCallState();
      return;
    }
    print(">>>> Permissions granted.");

    if (!_isAudioInitialized) {
      print(">>>> Audio playback not initialized, initializing now...");
      await _initializeAudioPlayback();
    }

    print(">>>> Creating RTCPeerConnection...");
    try {
      _peerConnection = await createPeerConnection(_rtcConfiguration);
      if (_peerConnection == null) {
        throw Exception("createPeerConnection returned null");
      }
      print(">>>> RTCPeerConnection created successfully.");
      await _processQueuedSignals();
      print(">>>> Setting up PeerConnection listeners...");
      _peerConnection!.onIceCandidate = (candidate) {
        print(
            ">>>> ICE Candidate generated: ${candidate.candidate?.substring(0, min(30, candidate.candidate?.length ?? 0))}...");
        _sendWebRTCSignal(
            {'type': 'candidate', 'candidate': candidate.toMap()});
      };

      _peerConnection!.onIceConnectionState = (state) {
        print(">>>> ICE Connection State changed: $state");
        if (state == RTCIceConnectionState.RTCIceConnectionStateFailed) {
          print('!!!! ICE Connection Failed !!!!');
          _closeWebRTCSession(notifyServer: true);
          setStateIfMounted(() {
            _callStatus = 'Connection Failed (ICE)';
          });
        } else if (state ==
                RTCIceConnectionState.RTCIceConnectionStateConnected ||
            state == RTCIceConnectionState.RTCIceConnectionStateCompleted) {
          print(">>>> ICE Connection established.");
        }
      };

      _peerConnection!.onConnectionState = (state) {
        print('>>>> PeerConnection State changed: $state');
        if (state == RTCPeerConnectionState.RTCPeerConnectionStateConnected &&
            _isInCall) {
          print(">>>> PeerConnection CONNECTED.");
          setStateIfMounted(() {
            _callStatus = 'Securely Connected';
          });
        } else if (state ==
            RTCPeerConnectionState.RTCPeerConnectionStateFailed) {
          print("!!!! PeerConnection FAILED !!!!");
          _closeWebRTCSession(notifyServer: true);
          setStateIfMounted(() {
            _callStatus = 'Connection Failed (Peer)';
          });
        } else if ((state ==
                    RTCPeerConnectionState.RTCPeerConnectionStateDisconnected ||
                state == RTCPeerConnectionState.RTCPeerConnectionStateClosed) &&
            _isInCall) {
          print("!!!! PeerConnection Disconnected or Closed unexpectedly.");
          _closeWebRTCSession(notifyServer: false);
          if (!(_callStatus.contains("ended by") ||
              _callStatus.contains("rejected"))) {
            setStateIfMounted(() {
              _callStatus = 'Call disconnected.';
            });
          }
        }
      };

      _peerConnection!.onIceGatheringState = (state) {
        print('>>>> ICE Gathering State changed: $state');
      };

      _peerConnection!.onDataChannel = (channel) {
        print(
            ">>>> Remote DataChannel received: Label: ${channel.label}, ID: ${channel.id}, State: ${channel.state}");
        _remoteDataChannel = channel;
        _setupDataChannelListeners(_remoteDataChannel!);
      };

      print(">>>> Creating local DataChannel 'audioChannel'...");
      RTCDataChannelInit dataChannelDict = RTCDataChannelInit()
        ..ordered = true
        ..maxRetransmits = 0;

      _dataChannel =
          await _peerConnection!.createDataChannel('audioChannel', dataChannelDict);
      if (_dataChannel == null) {
        throw Exception("createDataChannel returned null");
      }
      print(
          ">>>> Local DataChannel created: Label: ${_dataChannel!.label}, ID: ${_dataChannel!.id}, State: ${_dataChannel!.state}");
      _setupDataChannelListeners(_dataChannel!);
      await _processQueuedSignals();
      if (isInitiator) {
        print(">>>> Initiator creating Offer...");
        RTCSessionDescription offer = await _peerConnection!.createOffer(
            {'offerToReceiveAudio': true, 'offerToReceiveVideo': false});
        print(">>>> Offer created. Setting local description...");
        await _peerConnection!.setLocalDescription(offer);
        print(">>>> Local description set. Sending offer...");
        _sendWebRTCSignal(offer.toMap());
      } else {
        print(">>>> Receiver waiting for Offer...");
      }
    } catch (e, s) {
      print("!!!! Error starting WebRTC session: $e");
      print("!!!! Stack trace: $s");
      setStateIfMounted(() {
        _callStatus = "WebRTC Error: $e";
      });
      _closeWebRTCSession(notifyServer: true);
    }
  }

  void _setupDataChannelListeners(RTCDataChannel channel) {
    print(
        ">>>> Setting up listeners for DataChannel: Label: ${channel.label}, ID: ${channel.id}");
    channel.onDataChannelState = (state) {
      print(
          ">>>> DataChannel State (${channel.label}, ID: ${channel.id}): $state");
      if (state == RTCDataChannelState.RTCDataChannelOpen) {
        print(
            ">>>> DataChannel OPEN! (${channel.label}, ID: ${channel.id}). Attempting to start mic stream...");
        if (channel == _dataChannel &&
            _peerConnection?.connectionState ==
                RTCPeerConnectionState.RTCPeerConnectionStateConnected) {
          _startMicStream(channel);
        } else if (channel == _remoteDataChannel) {
          print(">>>> Remote DataChannel opened. Ready to receive.");
        }
      } else if (state == RTCDataChannelState.RTCDataChannelClosed) {
        print("!!!! DataChannel CLOSED! (${channel.label}, ID: ${channel.id})");
        if (channel == _dataChannel || channel == _remoteDataChannel) {
          print(">>>> Stopping mic stream due to DataChannel closure.");
          _stopMicStream();
        }
      } else if (state == RTCDataChannelState.RTCDataChannelClosing) {
        print(">>>> DataChannel Closing (${channel.label}, ID: ${channel.id})");
      } else if (state == RTCDataChannelState.RTCDataChannelConnecting) {
        print(
            ">>>> DataChannel Connecting (${channel.label}, ID: ${channel.id})");
      }
    };

    channel.onMessage = (RTCDataChannelMessage message) {
      // print(">>>> DataChannel (${channel.label}, ID: ${channel.id}) Received message.");
      if (message.isBinary) {
        _handleEncryptedAudioData(message.binary);
      } else {
        print(
            "!!!! Received non-binary message on data channel: ${message.text}");
      }
    };

    // --- FIX 2: Removed onError setter ---
    // channel.onError = (error) { // This setter doesn't exist
    //   print("!!!! DataChannel Error (${channel.label}, ID: ${channel.id}): $error");
    // };
    // --- End FIX 2 ---
  }

  Future<void> _checkAndRecoverAudioChain() async {
  // Conditions for recovery:
  // 1. Buffer is not empty.
  // 2. We are *not* currently in the middle of the play-chain (`_isProcessingBuffer` is false)
  //    OR we *think* we are processing, but the player state says it's not actually playing.
  final playerState = _audioPlayer?.state; // Get current state

  if (_audioBuffer.isNotEmpty &&
      (!_isProcessingBuffer || (_isProcessingBuffer && playerState != PlayerState.playing)))
  {
    print(">>>> RECOVERY DETECTED: Buffer: ${_audioBuffer.length}, Processing: $_isProcessingBuffer, PlayerState: $playerState. Attempting restart.");

    // Force reset of processing state JUST IN CASE it was stuck true.
    if (_isProcessingBuffer) {
       setStateIfMounted(() => _isProcessingBuffer = false);
       // Short delay to allow state update before trying to play again
       await Future.delayed(Duration(milliseconds: 50));
    }

    // Attempt to restart the chain by playing the next chunk
    _playNextChunkFromBuffer();
  }
}
  
  Future<void> _handleWebRTCSignal(Map<String, dynamic> signal) async {
   final type = signal['type'] as String?;
   print(">>>> Handling received WebRTC signal (Type: $type)");

   // --- MODIFICATION START ---
   if (_peerConnection == null) {
     // Check if QKD is done and we *should* be setting up WebRTC
     if (_qkdState == QkdState.success) {
         print("!!!! PeerConnection is null, but QKD succeeded. Queueing signal (Type: $type).");
         _queuedWebRTCSignals.add(signal);
     } else {
         // Should not happen if called from _handleWebRTCSignalAction, but safety check.
         print("!!!! WebRTC signal ignored: PeerConnection is null and QKD not successful ($_qkdState).");
     }
     return; // Don't process further if null
   }
   // --- MODIFICATION END ---

   // If _peerConnection is NOT null, proceed as before:
   if (_qkdState != QkdState.success) { // This check might be redundant now but safe
     print("!!!! WebRTC signal ignored: QKD not successful ($_qkdState).");
     return;
   }

   try {
     switch (type) {
       case 'offer':
         print(">>>> Handling OFFER signal...");
         if (_peerConnection!.signalingState != RTCSignalingState.RTCSignalingStateStable &&
             _peerConnection!.signalingState != RTCSignalingState.RTCSignalingStateHaveRemoteOffer) {
           print(
               "!!!! Received Offer in unexpected state: ${_peerConnection!.signalingState}. Potential glare?");
         }
         print(">>>> Setting remote description (Offer)...");
         await _peerConnection!.setRemoteDescription(
             RTCSessionDescription(signal['sdp'], signal['type']));
         print(">>>> Remote description (Offer) set. Creating Answer...");
         RTCSessionDescription answer = await _peerConnection!.createAnswer();
         print(">>>> Answer created. Setting local description (Answer)...");
         await _peerConnection!.setLocalDescription(answer);
         print(">>>> Local description (Answer) set. Sending Answer...");
         _sendWebRTCSignal(answer.toMap());
         break;

       case 'answer':
         print(">>>> Handling ANSWER signal...");
         if (_peerConnection!.signalingState != RTCSignalingState.RTCSignalingStateHaveLocalOffer) {
           print(
               "!!!! Received Answer in unexpected state: ${_peerConnection!.signalingState}.");
         }
         print(">>>> Setting remote description (Answer)...");
         await _peerConnection!.setRemoteDescription(
             RTCSessionDescription(signal['sdp'], signal['type']));
         print(">>>> Remote description (Answer) set.");
         break;

       case 'candidate':
         print(">>>> Handling CANDIDATE signal...");
         if (signal['candidate'] != null) {
           final candidateMap = signal['candidate'] as Map<String, dynamic>;
           RTCIceCandidate candidate = RTCIceCandidate(
             candidateMap['candidate'] as String? ?? '',
             candidateMap['sdpMid'] as String?,
             candidateMap['sdpMLineIndex'] as int?,
           );
           RTCSessionDescription? remoteDesc = await _peerConnection!.getRemoteDescription();
           if (remoteDesc != null) {
             print(">>>> Adding ICE Candidate (remote description exists)...");
             await _peerConnection!.addCandidate(candidate);
             print(">>>> ICE Candidate added.");
           } else {
             print("!!!! Received candidate before remote description set. Queueing signal instead.");
             // Also queue candidates if remote description isn't set yet
              _queuedWebRTCSignals.add(signal);
           }
         } else {
           print("!!!! Received null candidate field in candidate signal.");
         }
         break;
       default:
         print("!!!! Received unknown WebRTC signal type: $type");
     }
   } catch (e, s) {
     print("!!!! Error handling WebRTC signal (Type: $type): $e");
     print("!!!! Stack trace: $s");
   }
 }

  void _sendWebRTCSignal(Map<String, dynamic> data) {
    if (_remoteUserId != null) {
      print(
          ">>>> Queuing WebRTC signal (Type: ${data['type']}) for sending to $_remoteUserId");
      _sendMessage({
        'action': 'webrtcSignal',
        'toId': _remoteUserId!,
        'fromId': _myId,
        'data': data
      });
    } else {
      print("!!!! Cannot send WebRTC signal: remoteUserId is null.");
    }
  }

  // --- Audio Capture (Using record), Encryption, Sending ---
  Future<void> _startMicStream(RTCDataChannel channel) async {
    if (_isRecording) {
      print(">>>> Mic stream already recording.");
      return;
    }
    if (!mounted) {
      print("!!!! Cannot start mic stream: Widget not mounted.");
      return;
    }
    if (channel.state != RTCDataChannelState.RTCDataChannelOpen) {
      print(
          "!!!! Attempted to start mic stream but DataChannel state is ${channel.state}");
      return;
    }
    if (_sharedKey == null) {
      print("!!!! Cannot start mic stream: Shared key is null.");
      return;
    }
    print(
        ">>>> Entering _startMicStream for channel ${channel.label}, ID: ${channel.id}");

    if (!await _requestPermissions()) {
      print("!!!! Mic permission denied in _startMicStream");
      setStateIfMounted(() => _callStatus = "Microphone Permission Denied");
      return;
    }

    try {
      print(">>>> Attempting to start audio stream with 'record' plugin...");
      final stream = await _audioRecorder.startStream(
        const RecordConfig(
          encoder: AudioEncoder.pcm16bits,
          sampleRate: recordSampleRate,
          numChannels: 1,
        ),
      );
      print(">>>> Audio stream started successfully via 'record'.");

      _audioChunkSubscription = stream.listen(
        (audioChunk) {
          print(">>>> Audio chunk received: ${audioChunk.length} bytes");
          if (!mounted) {
            print(
                "!!!! Audio chunk listener fired but widget not mounted. Cancelling subscription.");
            _audioChunkSubscription?.cancel();
            _audioChunkSubscription = null;
            _stopMicStream();
            return;
          }
          if (_sharedKey != null &&
              channel.state == RTCDataChannelState.RTCDataChannelOpen) {
            Uint8List? encryptedData = _encryptAudioChunk(audioChunk);
            if (encryptedData != null) {
              // print(">>>> Sending encrypted chunk: ${encryptedData.length} bytes");
              try {
                channel.send(RTCDataChannelMessage.fromBinary(encryptedData));
              } catch (e) {
                print("!!!! Error sending data channel message: $e");
                if (e.toString().contains("Closing") ||
                    e.toString().contains("Closed")) {
                  _stopMicStream();
                }
              }
            } else {
              print("!!!! Encryption failed for audio chunk.");
            }
          } else {
            print(
                "!!!! Cannot send audio chunk: Shared key is null or channel state is not Open (${channel.state}). Stopping stream.");
            _stopMicStream();
          }
        },
        onError: (e) {
          print("!!!! Audio stream listener error: $e");
          setStateIfMounted(() => _isRecording = false);
          _stopMicStream();
        },
        onDone: () {
          print(">>>> Audio stream listener 'onDone' called (stream ended).");
          if (mounted) {
            setState(() => _isRecording = false);
          }
          _stopMicStream();
        },
        cancelOnError: true,
      );
      print(">>>> Audio stream listener attached.");

      // --- FIX 6: Use isRecording() instead of getRecordState() ---
      final bool currentlyRecording = await _audioRecorder.isRecording();
      print(">>>> Current recorder state after startStream: ${currentlyRecording ? 'Recording' : 'Not Recording'}");
      if (mounted) {
        setState(() => _isRecording = currentlyRecording);
      }
      // --- End FIX 6 ---

    } catch (e, s) {
      print("!!!! Failed to start mic stream using 'record': $e");
      print("!!!! Stack trace: $s");
      if (mounted) {
        setState(() => _isRecording = false);
      }
    }
  }

  Future<void> _stopMicStream() async {
    print(
        ">>>> Entering _stopMicStream. Current recording state: $_isRecording");
    if (!_isRecording && _audioChunkSubscription == null) {
      print(">>>> Mic stream already stopped or subscription cancelled.");
      try {
        if (await _audioRecorder.isRecording()) {
          print(
              ">>>> Inconsistency found: _isRecording is false but recorder thinks it's recording. Stopping now.");
          await _audioRecorder.stop();
        }
      } catch (e) {
        print(
            "!!!! Error checking/stopping recorder in _stopMicStream consistency check: $e");
      }
      return;
    }

    print(">>>> Stopping 'record' recorder and cancelling subscription...");
    try {
      await _audioChunkSubscription?.cancel();
      _audioChunkSubscription = null;
      print(">>>> Audio chunk subscription cancelled.");

      if (await _audioRecorder.isRecording()) {
        await _audioRecorder.stop();
        print(">>>> Audio recorder stopped.");
      } else {
        print(">>>> Audio recorder was already stopped.");
      }

      if (mounted && _isRecording) {
        print(
            ">>>> Manually setting _isRecording to false in _stopMicStream as a fallback.");
        setState(() => _isRecording = false);
      }
    } catch (e, s) {
      print(
          "!!!! Error stopping 'record' recorder or cancelling subscription: $e");
      print("!!!! Stack trace: $s");
      if (mounted) setState(() => _isRecording = false);
      _audioChunkSubscription = null;
    }
    print(">>>> Exiting _stopMicStream.");
  }

  Uint8List? _encryptAudioChunk(Uint8List audioChunk) {
    if (_sharedKey == null) {
      print("!!!! Encrypt Error: Shared key is null.");
      return null;
    }
    if (_sharedKey!.length != aesKeyLengthBytes) {
      print(
          "!!!! Encrypt Error: Shared key has incorrect length (${_sharedKey!.length}).");
      return null;
    }

    try {
      final nonce = _generateSecureNonce();
      final cipher = pc.GCMBlockCipher(pc.AESFastEngine());
      final params = pc.AEADParameters(
          pc.KeyParameter(_sharedKey!), gcmTagLengthBits, nonce, Uint8List(0));
      cipher.init(true, params);
      Uint8List encryptedChunk = cipher.process(audioChunk);

      final combined = Uint8List(gcmNonceLengthBytes + encryptedChunk.length);
      combined.setRange(0, gcmNonceLengthBytes, nonce);
      combined.setRange(gcmNonceLengthBytes, combined.length, encryptedChunk);
      // print(">>>> Encryption successful: Input ${audioChunk.length}, Output ${combined.length}");
      return combined;
    } catch (e, s) {
      print("!!!! Encryption failed: $e");
      print("!!!! Stack trace: $s");
      return null;
    }
  }

  Future<void> _processQueuedSignals() async {
  if (_queuedWebRTCSignals.isEmpty) {
    return; // Nothing to process
  }

  print(">>>> Processing ${_queuedWebRTCSignals.length} queued WebRTC signals...");
  // Create a copy to iterate over, allowing _handleWebRTCSignal to potentially re-queue candidates
  List<Map<String, dynamic>> signalsToProcess = List.from(_queuedWebRTCSignals);
  _queuedWebRTCSignals.clear(); // Clear original queue

  for (final signal in signalsToProcess) {
     print(">>>> Processing queued signal (Type: ${signal['type']})");
     await _handleWebRTCSignal(signal); // Process it now that peerConnection exists
  }
  print(">>>> Finished processing queued signals.");

  // It's possible candidates were re-queued if remote description wasn't ready
  // during the loop. Check if the queue has new items and process again if needed.
  // This is a simple way to handle candidate timing.
  if (_queuedWebRTCSignals.isNotEmpty) {
     print(">>>> Re-processing newly queued signals (likely candidates)...");
     await _processQueuedSignals(); // Recursive call to handle re-queued signals
  }
}

  Uint8List _generateSecureNonce() {
    final secureRandom = pc.FortunaRandom();
    final seedSource = Random.secure();
    final seeds =
        Uint8List.fromList(List.generate(32, (_) => seedSource.nextInt(256)));
    secureRandom.seed(pc.KeyParameter(seeds));
    return secureRandom.nextBytes(gcmNonceLengthBytes);
  }


Future<void> _initializeAudioPlayback() async {
  if (_audioPlayer != null) {
    print(">>>> Audio playback already initialized.");
    return;
  }
  print(">>>> Initializing audio playback (AudioPlayer)...");

  // --- Add Recovery Timer ---
  // (Ensure it's cancelled in dispose and _closeWebRTCSession if needed)
  _audioRecoveryTimer?.cancel(); // Cancel any existing timer
  _audioRecoveryTimer = Timer.periodic(Duration(seconds: 3), (_) {
    // Only run recovery if in call, QKD succeeded, and buffer has data
    if (_isInCall && _qkdState == QkdState.success && _audioBuffer.isNotEmpty) {
       _checkAndRecoverAudioChain();
    }
  });
  // --- End Add Recovery Timer ---


  _audioPlayer = AudioPlayer();
  _audioPlayer!.setReleaseMode(ReleaseMode.stop); // Keep using stop for manual queue

  print(">>>> Forcing speakerphone ON using AudioContext...");
  try {
    await _audioPlayer!.setAudioContext(AudioContext(
      android: AudioContextAndroid(
        isSpeakerphoneOn: true,
        stayAwake: true,
        contentType: AndroidContentType.speech,
        usageType: AndroidUsageType.voiceCommunication,
        audioFocus: AndroidAudioFocus.gain,
      ),
      // ios: ... // Add iOS context if needed
    ));
    print(">>>> AudioContext set for speakerphone.");
    setStateIfMounted(() => _isSpeakerphoneOn = true);
  } catch (e) {
    print("!!!! Failed to set AudioContext: $e");
  }

  // Cancel previous subscriptions (safety)
  await _playerStateSubscription?.cancel();
  await _playerCompleteSubscription?.cancel();

  _playerStateSubscription = _audioPlayer!.onPlayerStateChanged.listen(
    (state) {
      // print(">>>> AudioPlayer state changed: $state. isProcessing: $_isProcessingBuffer");
      // Update UI state
      if (mounted) {
        final bool nowPlaying = (state == PlayerState.playing);
        if (_isPlayingAudio != nowPlaying) {
          setState(() {
            _isPlayingAudio = nowPlaying;
          });
        }
      }
      // Handle unexpected stops
      if ((state == PlayerState.stopped || state == PlayerState.completed) &&
          _isProcessingBuffer && // If we *thought* we were playing
          _audioBuffer.isNotEmpty) { // And there's more data
          print("!!!! Player stopped/completed unexpectedly while processing buffer. Buffer: ${_audioBuffer.length}. Attempting recovery.");
          // This might indicate onComplete didn't fire or was too late.
          // The recovery timer will likely handle this, but we can try here too.
          setStateIfMounted(() => _isProcessingBuffer = false); // Reset flag
          _playNextChunkFromBuffer(); // Try to restart the chain immediately
      }
    },
    onError: (msg) {
      print('!!!! AudioPlayer error: $msg');
      setStateIfMounted(() {
        _isPlayingAudio = false;
        if (_isProcessingBuffer) {
             print("!!!! AudioPlayer error occurred while processing buffer. Resetting flag.");
             _isProcessingBuffer = false; // *** Crucial: Reset flag on error ***
        }
      });
      _audioBuffer.clear(); // Clear buffer on error
      // Consider stopping completely or attempting recovery after a delay
      // _stopAudioPlayer();
    },
  );

  _playerCompleteSubscription = _audioPlayer!.onPlayerComplete.listen((_) {
    // print(">>>> AudioPlayer playback complete (onPlayerComplete). Buffer: ${_audioBuffer.length}");
    final bool wasProcessing = _isProcessingBuffer; // Log previous state
    setStateIfMounted(() => _isProcessingBuffer = false);
    // print(">>>> Playback complete. Reset processing flag (was $wasProcessing). Buffer size: ${_audioBuffer.length}");

    // Immediately try to play the next chunk *if available*
    if (_audioBuffer.isNotEmpty) {
      // print(">>>> onPlayerComplete: Buffer not empty, triggering next playback.");
      _playNextChunkFromBuffer();
    } else {
      // print(">>>> onPlayerComplete: Buffer empty, playback chain naturally stops.");
    }
  });

  _isAudioInitialized = true;
  print(">>>> Audio playback initialized successfully.");
  await _setSpeakerphone(_isSpeakerphoneOn); // Apply initial state
}


void _handleEncryptedAudioData(Uint8List encryptedData) {
  // print(">>>> Handling encrypted audio data: ${encryptedData.length} bytes");
  if (_sharedKey == null) {
    print("!!!! Decrypt Error: Shared key is null.");
    return;
  }
  // ... (rest of decryption logic remains the same) ...
  try {
    // ... decryption ...
    final nonce = encryptedData.sublist(0, gcmNonceLengthBytes);
    final ciphertextWithTag = encryptedData.sublist(gcmNonceLengthBytes);

    final cipher = pc.GCMBlockCipher(pc.AESFastEngine());
    final params = pc.AEADParameters(
        pc.KeyParameter(_sharedKey!), gcmTagLengthBits, nonce, Uint8List(0));
    cipher.init(false, params); // False for decryption

    Uint8List decryptedBytes = cipher.process(ciphertextWithTag);


    if (decryptedBytes.isNotEmpty) {
      _audioBuffer.add(decryptedBytes);
       // print(">>>> Chunk added to buffer. Size: ${_audioBuffer.length}. isProcessing: $_isProcessingBuffer");

      // --- Kick off playback ONLY if the player is currently idle ---
      // This check remains critical to prevent multiple playback chains starting.
      if (!_isProcessingBuffer) {
          // print(">>>> Player is idle (_isProcessingBuffer is false), attempting to start playback from buffer.");
          _playNextChunkFromBuffer();
      } else {
          // print(">>>> Player is busy (_isProcessingBuffer is true), chunk queued. onComplete will handle next play.");
      }
    } else {
       print(">>>> Decryption resulted in empty data, discarding.");
    }

  } on pc.InvalidCipherTextException catch (e) {
    print("!!!! Decryption failed (InvalidCipherTextException): Authentication tag check failed. $e");
    // Don't clear buffer here, maybe just one corrupted packet
  } catch (e, s) {
    print("!!!! Decryption or Buffer Add failed: $e");
    print("!!!! Stack trace: $s");
    // Consider clearing buffer on major errors? Depends on desired behaviour.
    // _audioBuffer.clear();
    // setStateIfMounted(() => _isProcessingBuffer = false);
  }
}


Future<void> _stopAudioPlayer() async {
  print(">>>> Stopping audio player and clearing buffer...");
  _audioBuffer.clear(); // Clear any pending chunks

  // Reset the processing flag *before* stopping the player
  final wasProcessing = _isProcessingBuffer;
  setStateIfMounted(() => _isProcessingBuffer = false);
  print(">>>> Reset processing flag in stopAudioPlayer (was $wasProcessing).");

  // Stop the recovery timer when stopping playback
  _audioRecoveryTimer?.cancel();
  _audioRecoveryTimer = null;

  if (_audioPlayer != null) {
    try {
      await _audioPlayer!.stop();
      print(">>>> Audio player stopped successfully via stop().");
      // State listener should update _isPlayingAudio to false eventually.
    } catch (e) {
      print("!!!! Error stopping audio player: $e");
    }
  } else {
    print(">>>> Audio player was already null.");
  }

  // Ensure UI reflects stopped state immediately as a fallback
  if (mounted && _isPlayingAudio) {
    print(">>>> Manually setting _isPlayingAudio to false in stopAudioPlayer.");
    setState(() => _isPlayingAudio = false);
  }
}

  Future<void> _setSpeakerphone(bool enable) async {
    if (kIsWeb) {
      print(">>>> Speakerphone control not available on Web.");
      return;
    }
    print(">>>> Setting speakerphone to: $enable");
    try {
      await Helper.setSpeakerphoneOn(enable); // Uses placeholder
      setStateIfMounted(() => _isSpeakerphoneOn = enable);
      print(">>>> Speakerphone state updated.");
    } catch (e) {
      print("!!!! Speakerphone toggle/set failed: $e");
    }
  }

  void _toggleSpeakerphone() {
    print(">>>> Toggling speakerphone. Current state: $_isSpeakerphoneOn");
    _setSpeakerphone(!_isSpeakerphoneOn);
  }

  // --- Permission Handling ---
  Future<bool> _requestPermissions() async {
    print(">>>> Checking microphone permission...");
    var status = await Permission.microphone.status;
    print(">>>> Current microphone permission status: $status");

    if (status.isGranted) {
      print(">>>> Microphone permission already granted.");
      return true;
    } else { // Covers denied, permanently denied, restricted, limited
      print(">>>> Requesting microphone permission...");
      status = await Permission.microphone.request();
      print(">>>> Permission request result: $status");
      if (status.isGranted) {
        print(">>>> Microphone permission granted after request.");
        return true;
      } else if (status.isPermanentlyDenied) {
         print("!!!! Microphone permission permanently denied. Open settings to enable.");
         // Optionally show a dialog prompting the user to open settings
         // openAppSettings();
         return false;
      }
      else {
        print("!!!! Microphone permission denied or restricted after request.");
        return false;
      }
    }
  }


  // --- Cleanup Logic ---
  Future<void> _closeWebRTCSession({required bool notifyServer}) async {
    print(">>>> Entering _closeWebRTCSession (Notify Server: $notifyServer)...");
    _audioRecoveryTimer?.cancel();
    _queuedWebRTCSignals.clear(); 
    if (_peerConnection == null &&
        _dataChannel == null &&
        _remoteDataChannel == null &&
        !_isRecording) {
      print(">>>> WebRTC session already appears closed.");
      _resetCallState();
      return;
    }

    if (notifyServer &&
        _remoteUserId != null &&
        _channel != null &&
        _channel!.closeCode == null) {
      print(
          ">>>> Sending hangUp message to $_remoteUserId due to local closure.");
      _sendMessage(
          {'action': 'hangUp', 'toId': _remoteUserId!, 'fromId': _myId});
    }

    await _stopMicStream();
    await _stopAudioPlayer();

    try {
      if (_dataChannel != null) {
        print(">>>> Closing local data channel (ID: ${_dataChannel?.id})...");
        await _dataChannel!.close();
        print(">>>> Local data channel closed.");
      }
    } catch (e) {
      print("!!!! Error closing local data channel: $e");
    }
    _dataChannel = null;

    try {
      if (_remoteDataChannel != null) {
        print(
            ">>>> Closing remote data channel (ID: ${_remoteDataChannel?.id})...");
        await _remoteDataChannel!.close();
        print(">>>> Remote data channel closed.");
      }
    } catch (e) {
      print("!!!! Error closing remote data channel: $e");
    }
    _remoteDataChannel = null;

    try {
      if (_peerConnection != null) {
        print(">>>> Closing PeerConnection...");
        await _peerConnection!.close();
        print(">>>> PeerConnection closed.");
      }
    } catch (e) {
      print("!!!! Error closing PeerConnection: $e");
    }
    _peerConnection = null;

    try {
      await _localStream?.dispose();
    } catch (e) {/* Ignore */
    }
    _localStream = null;
    try {
      await _remoteStream?.dispose();
    } catch (e) {/* Ignore */
    }
    _remoteStream = null;

    _qkdSimulator?.reset();
    _qkdSimulator = null;

    _resetCallState();
    print(">>>> _closeWebRTCSession finished.");
  }

  void _resetCallState() {
    print(">>>> Resetting call state...");
    _queuedWebRTCSignals.clear();
    bool wasInCall = _isInCall;

    _qkdSimulator?.reset();
    _qkdSimulator = null;
    _sharedKey = null;

    if (mounted) {
      setState(() {
        bool hadError = _callStatus.contains("Error") ||
            _callStatus.contains("Failed") ||
            _callStatus.contains("Permission");
        bool wasDisconnected =
            _callStatus.contains("disconnect") || _callStatus.contains("Lost");
        bool wasEnded = _callStatus.contains("ended by");
        bool wasRejected = _callStatus.contains("rejected");

        _isInCall = false;
        _remoteUserId = null;
        _qkdState = QkdState.idle;

        if (!wasInCall ||
            (!hadError && !wasDisconnected && !wasEnded && !wasRejected)) {
          _callStatus = 'Ready';
        } else {
          print(">>>> Preserving call status: $_callStatus");
        }
        _isRecording = false;
        _isPlayingAudio = false;
      });
    } else {
      _isInCall = false;
      _remoteUserId = null;
      _qkdState = QkdState.idle;
      _sharedKey = null;
      _isRecording = false;
      _isPlayingAudio = false;
    }
    print(
        ">>>> Call state reset complete. InCall: $_isInCall, Status: $_callStatus");
  }

  void setStateIfMounted(VoidCallback fn) {
    if (mounted) {
      setState(fn);
    } else {
      print(">>>> setStateIfMounted: Widget not mounted, skipping setState.");
    }
  }

  // --- Digit Handling Functions ---
  void _addDigit(String digit) {
    if (!_isInCall && _enteredNumber.length < 10) {
      setStateIfMounted(() {
        _enteredNumber += digit;
      });
    }
  }

  void _deleteDigit() {
    if (!_isInCall && _enteredNumber.isNotEmpty) {
      setStateIfMounted(() {
        _enteredNumber =
            _enteredNumber.substring(0, _enteredNumber.length - 1);
      });
    }
  }

  // --- Build UI ---
  @override
  Widget build(BuildContext context) {
    // print(">>>> DialerScreen building UI. InCall: $_isInCall, Status: $_callStatus");
    return Scaffold(
      appBar: AppBar(
        title: Text('My ID: $_myId', style: TextStyle(fontSize: 16)),
        centerTitle: true,
        actions: [
          Padding(
            padding: const EdgeInsets.only(right: 8.0),
            child: Center(
                child: Text(_connectionStatus,
                    style: TextStyle(
                        fontSize: 12,
                        color: _connectionStatus.startsWith('Reg')
                            ? Colors.green
                            : (_connectionStatus.contains('Error') ||
                                    _connectionStatus == 'Disconnected'
                                ? Colors.red
                                : Colors.orange)))),
          ),
        ],
        leading: _connectionStatus == 'Disconnected' ||
                _connectionStatus.contains('Error')
            ? IconButton(
                icon: Icon(Icons.sync_problem, color: Colors.orange),
                tooltip: 'Reconnect WebSocket',
                onPressed: _connectWebSocket)
            : null,
      ),
      body: Column(children: <Widget>[
        Container(
            padding: const EdgeInsets.symmetric(vertical: 12, horizontal: 20),
            color: _callStatus.contains("Error") || _callStatus.contains("Failed")
                ? Colors.red[100]
                : (_qkdState == QkdState.success && _isInCall)
                    ? Colors.lightGreen[100]
                    : (_qkdState == QkdState.exchanging ||
                            _callStatus.contains("Connecting"))
                        ? Colors.amber[100]
                        : Colors.blueGrey[100],
            width: double.infinity,
            child: Text(_callStatus.isEmpty ? 'Ready' : _callStatus,
                textAlign: TextAlign.center,
                style: TextStyle(
                    fontWeight: FontWeight.bold,
                    fontSize: 16,
                    color: _callStatus.contains("Error") ||
                            _callStatus.contains("Failed")
                        ? Colors.red[900]
                        : Colors.black87))),
        Expanded(
            child: AnimatedSwitcher(
          duration: const Duration(milliseconds: 300),
          child: _isInCall ? _buildInCallView() : _buildDialerView(),
        ))
      ]),
      floatingActionButtonLocation: FloatingActionButtonLocation.centerFloat,
      floatingActionButton: _isInCall
          ? FloatingActionButton(
              onPressed: _hangUp,
              backgroundColor: Colors.red,
              tooltip: 'Hang Up',
              child: const Icon(Icons.call_end, color: Colors.white),
            )
          : null,
    );
  }

  Widget _buildDialerView() {
    return Column(
        key: const ValueKey('dialerView'),
        children: <Widget>[
          Expanded(
              flex: 2,
              child: Container(
                  alignment: Alignment.center,
                  padding: const EdgeInsets.symmetric(horizontal: 20.0),
                  child: Text(
                      _enteredNumber.isEmpty ? 'Enter Target ID' : _enteredNumber,
                      style: TextStyle(
                          fontSize: 34.0,
                          fontWeight: FontWeight.bold,
                          letterSpacing: 2.0,
                          color: _enteredNumber.isEmpty
                              ? Colors.grey[400]
                              : Colors.black),
                      textAlign: TextAlign.center))),
          Expanded(
              flex: 5,
              child: Padding(
                  padding: const EdgeInsets.symmetric(
                      horizontal: 20.0, vertical: 10.0),
                  child: Column(
                      mainAxisAlignment: MainAxisAlignment.spaceEvenly,
                      children: [
                        _buildNumberRow(['1', '2', '3']),
                        _buildNumberRow(['4', '5', '6']),
                        _buildNumberRow(['7', '8', '9']),
                        Row(
                            mainAxisAlignment: MainAxisAlignment.spaceEvenly,
                            children: <Widget>[
                              _buildEmptyButton(),
                              _buildNumberButton('0'),
                              _buildActionButton(
                                  icon: Icons.backspace_outlined,
                                  onPressed: _deleteDigit,
                                  color: Colors.grey[300],
                                  iconColor: Colors.black54)
                            ])
                      ]))),
          Padding(
              padding: const EdgeInsets.fromLTRB(20.0, 10.0, 20.0, 30.0),
              child: SizedBox(
                  width: double.infinity,
                  height: 60,
                  child: ElevatedButton.icon(
                    icon: const Icon(Icons.phonelink_ring_outlined, size: 28),
                    label: const Text('Connect Securely'),
                    style: ElevatedButton.styleFrom(
                        backgroundColor: Colors.green,
                        foregroundColor: Colors.white,
                        textStyle: const TextStyle(
                            fontSize: 20.0, fontWeight: FontWeight.bold),
                        shape: RoundedRectangleBorder(
                            borderRadius: BorderRadius.circular(30))),
                    onPressed: (_connectionStatus.startsWith('Registered') &&
                            _enteredNumber.length == 10)
                        ? _initiateSecureCall
                        : null,
                  ))),
        ]);
  }

  Widget _buildInCallView() {
    return Center(
        key: const ValueKey('inCallView'),
        child: Padding(
            padding: const EdgeInsets.all(20.0),
            child: Column(
                mainAxisAlignment: MainAxisAlignment.center,
                crossAxisAlignment: CrossAxisAlignment.center,
                children: [
                  Icon(
                      _qkdState == QkdState.success
                          ? Icons.lock_outline
                          : Icons.lock_open_outlined,
                      size: 50,
                      color: _qkdState == QkdState.success
                          ? Colors.green
                          : Colors.orange),
                  const SizedBox(height: 15),
                  Text(
                      _qkdState == QkdState.success
                          ? 'Secure Connection Established'
                          : 'Connecting...',
                      style: Theme.of(context).textTheme.titleMedium?.copyWith(
                          color: _qkdState == QkdState.success
                              ? Colors.green
                              : Colors.orange)),
                  const SizedBox(height: 8),
                  Text(_remoteUserId ?? 'Unknown',
                      style: Theme.of(context)
                          .textTheme
                          .headlineMedium
                          ?.copyWith(fontWeight: FontWeight.bold)),
                  const SizedBox(height: 50),
                  if (!kIsWeb &&
                      (defaultTargetPlatform == TargetPlatform.android ||
                          defaultTargetPlatform == TargetPlatform.iOS))
                    Column(
                      children: [
                        IconButton(
                          icon: Icon(_isSpeakerphoneOn
                              ? Icons.volume_up
                              : Icons.volume_down),
                          iconSize: 40,
                          tooltip: _isSpeakerphoneOn
                              ? 'Turn Speaker Off'
                              : 'Turn Speaker On',
                          onPressed: _toggleSpeakerphone,
                          color: Theme.of(context).colorScheme.primary,
                        ),
                        const SizedBox(height: 5),
                        Text(_isSpeakerphoneOn ? 'Speaker On' : 'Earpiece',
                            style:
                                TextStyle(fontSize: 12, color: Colors.grey[600])),
                      ],
                    ),
                  const Spacer(),
                  Row(
                    mainAxisAlignment: MainAxisAlignment.center,
                    children: [
                      Icon(
                        _isRecording ? Icons.mic : Icons.mic_off,
                        color: _isRecording ? Colors.red : Colors.grey,
                        size: 20,
                      ),
                      const SizedBox(width: 20),
                      Icon(
                        _isPlayingAudio
                            ? Icons.graphic_eq
                            : Icons.volume_mute,
                        color: _isPlayingAudio ? Colors.blue : Colors.grey,
                        size: 20,
                      ),
                    ],
                  ),
                  const SizedBox(height: 80),
                ])));
  }

  Widget _buildNumberRow(List<String> digits) {
    return Expanded(
        child: Row(
            mainAxisAlignment: MainAxisAlignment.spaceEvenly,
            children: digits.map((d) => _buildNumberButton(d)).toList()));
  }

  Widget _buildNumberButton(String digit) {
    return Expanded(
        child: Padding(
            padding: const EdgeInsets.all(6.0),
            child: ElevatedButton(
                onPressed: () => _addDigit(digit),
                style: ElevatedButton.styleFrom(
                    padding: const EdgeInsets.all(15.0),
                    shape: const CircleBorder(),
                    backgroundColor: Colors.blueGrey[50],
                    foregroundColor: Colors.black87,
                    elevation: 2),
                child: Text(digit,
                    style: const TextStyle(
                        fontSize: 26.0, fontWeight: FontWeight.w600)))));
  }

  Widget _buildActionButton(
      {required IconData icon,
      required VoidCallback onPressed,
      Color? color,
      Color? iconColor}) {
    return Expanded(
        child: Padding(
            padding: const EdgeInsets.all(6.0),
            child: ElevatedButton(
                onPressed: onPressed,
                style: ElevatedButton.styleFrom(
                    padding: const EdgeInsets.all(15.0),
                    shape: const CircleBorder(),
                    backgroundColor:
                        color ?? Theme.of(context).colorScheme.secondary,
                    foregroundColor: iconColor ?? Colors.white,
                    elevation: 2),
                child: Icon(icon, size: 28.0))));
  }

  Widget _buildEmptyButton() {
    return const Expanded(child: SizedBox());
  }
} // End of _DialerScreenState class