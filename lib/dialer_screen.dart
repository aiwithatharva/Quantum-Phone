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
import 'package:flutter_pcm_sound/flutter_pcm_sound.dart';
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


  bool _isAudioInitialized = false;
  bool _isSpeakerphoneOn = false;
  bool _isPcmSoundPlaying  = false;
  // --- ADD THESE LINES ---
  final Queue<List<int>> _audioBuffer = Queue<List<int>>();
  // --- END OF ADDED LINES ---
  bool _isRecording = false;
  bool _isPlayingAudio = false;


// --- ADD THIS NEW FUNCTION ---
// Place it somewhere logical, e.g., after _initializeAudioPlayback or _handleEncryptedAudioData
// Place this function inside the _DialerScreenState class



  @override
  void initState() {
    super.initState();
    _audioRecorder = AudioRecorder();
    WidgetsBinding.instance.addObserver(this);
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
      if (_isPcmSoundPlaying) _stopPcmSoundPlayback();
    }
  }

  @override
  void dispose() {
    print(">>>> DialerScreen disposing...");
    WidgetsBinding.instance.removeObserver(this);
    _channel?.sink.close(1000, "Client disposed");
    _closeWebRTCSession(notifyServer: false);

    _recordStateSubscription?.cancel();
    _amplitudeSubscription?.cancel();
    _audioRecorder.dispose();
    _audioChunkSubscription?.cancel();

    // Add FlutterPcmSound cleanup
    print(">>>> Releasing FlutterPcmSound resources...");
    FlutterPcmSound.release(); // Important!

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
      await _initializePcmSound();
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
// This function replaces _playNextChunkFromBuffer logic
Future<void> _onFeedPcmSound(int remainingFrames) async {
  // This callback runs frequently when playing. Keep it efficient.
  // Avoid heavy computations or long async operations here if possible.
print(">>>> _onFeedPcmSound CALLED. Remaining frames hint: $remainingFrames. Buffer size: ${_audioBuffer.length}");

  // Check if we actually have data buffered from the network
  if (_audioBuffer.isNotEmpty) {
    // Get the next chunk (already converted to List<int>)
    final List<int> pcmChunk = _audioBuffer.removeFirst();

    print(">>>> Feeding ${pcmChunk.length} samples. Buffer size now: ${_audioBuffer.length}. Remaining frames hint: $remainingFrames");

    try {
      // Feed the PCM data to the plugin
      // PcmArrayInt16.fromList expects List<int>
      await FlutterPcmSound.feed(PcmArrayInt16.fromList(pcmChunk));
      
    } catch (e, s) {
      print("!!!! Error feeding PCM data: $e");
      print("!!!! Stack trace: $s");
      // Consider clearing the buffer or stopping playback on feed errors
      _stopPcmSoundPlayback(); // Example: Stop on error
    }
  } else {
    // Buffer is empty. Don't feed anything.
    // The plugin will keep calling the callback until feedThreshold is reached again
    // or until the buffer runs completely dry.
    // print(">>>> PCM Feed callback: Buffer empty. Waiting for data.");
    // Optionally feed silence here if desired, but usually not necessary:
    // final List<int> silence = List<int>.filled(2048, 0); // Example: Feed ~128ms silence
    // await FlutterPcmSound.feed(PcmArrayInt16.fromList(silence));
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
          // print(">>>> Audio chunk received: ${audioChunk.length} bytes");
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


Future<void> _initializePcmSound() async {
  if (_isAudioInitialized) {
     print(">>>> FlutterPcmSound already initialized setup.");
     return; // Or call release() and setup() again if re-initialization is needed
  }
  print(">>>> Initializing FlutterPcmSound...");
  try {
    // Set log level for debugging if needed
    FlutterPcmSound.setLogLevel(LogLevel.verbose); // Or LogLevel.error

    // Setup the audio parameters
    await FlutterPcmSound.setup(
      sampleRate: recordSampleRate, // Use your consistent sample rate
      channelCount: 1, // Mono audio
    );

    // Set the buffer threshold. Lower values mean lower latency but more frequent callbacks.
    // Start with sampleRate / 10 (100ms buffer) and tune down if needed.
    // Example: 16000 / 10 = 1600 frames. Might need lower (e.g., 4000 or 2000).
    // The value is in *frames*.
    int feedThreshold = recordSampleRate ~/ 10; // ~100ms buffer initially
    print(">>>> Setting PCM feed threshold to: $feedThreshold frames");
    await FlutterPcmSound.setFeedThreshold(feedThreshold);

    // Set the callback that provides audio data
    FlutterPcmSound.setFeedCallback(_onFeedPcmSound); // <-- Link to the new callback

    _isAudioInitialized = true; // Mark as initialized
    print(">>>> FlutterPcmSound initialized successfully.");

    // Apply speakerphone setting if needed (using your existing Helper)
    await _setSpeakerphone(_isSpeakerphoneOn);

  } catch (e, s) {
    print("!!!! Failed to initialize FlutterPcmSound: $e");
    print("!!!! Stack trace: $s");
    _isAudioInitialized = false;
    setStateIfMounted(() {
      _callStatus = "Audio Init Error";
    });
  }
}

void _startPcmSoundPlayback() {
  if (!_isAudioInitialized) {
     print("!!!! Cannot start PCM sound: Not initialized.");
     return;
  }
  if (_isPcmSoundPlaying) {
    print(">>>> PCM sound already playing (callback likely active).");
    // If it's already "playing", the callback is set, and it will pull data when needed.
    // Calling the callback again might not be harmful but isn't strictly necessary
    // unless you want to force an immediate check even if the threshold isn't met.
    // For simplicity, we can just return if already marked as playing.
    return;
  }
  print(">>>> Triggering FlutterPcmSound playback by calling feed callback...");
  try {
      // --- REPLACEMENT ---
      // Instead of: FlutterPcmSound.start();
      // Directly call the feed callback to initiate the process.
      // Pass 0 for remainingFrames as per the documentation's equivalence note.
      FlutterPcmSound.play();
      _onFeedPcmSound(0);
      // --- END REPLACEMENT ---

      // We assume playback will start if the callback finds data.
      // The actual audio playing state depends on data being fed successfully.
      setStateIfMounted(() {
        _isPcmSoundPlaying = true; // Mark that we have initiated playback intent
        _isPlayingAudio = true;    // Update UI state accordingly
      });
      print(">>>> FlutterPcmSound playback initiated via manual callback trigger.");

  } catch (e, s) {
      // This catch might not be as relevant now since the error would likely
      // occur inside _onFeedPcmSound during the FlutterPcmSound.feed call.
      print("!!!! Error occurred during initial manual feed callback trigger: $e");
      print("!!!! Stack trace: $s");
      // Consider resetting state if the initial trigger fails critically
      setStateIfMounted(() {
         _isPcmSoundPlaying = false;
         _isPlayingAudio = false;
      });
  }
}


void _stopPcmSoundPlayback() {
  if (!_isPcmSoundPlaying && _audioBuffer.isEmpty) {
    print(">>>> PCM sound already stopped or idle.");
    return;
  }
  print(">>>> Stopping FlutterPcmSound playback (disabling callback)...");

  // Provide an empty callback instead of null
  FlutterPcmSound.setFeedCallback((int remainingFrames) {
    // Do nothing
  });

  _audioBuffer.clear(); // Clear any remaining buffered data

  setStateIfMounted(() {
    _isPcmSoundPlaying = false;
    _isPlayingAudio = false; // Update UI state
  });
  print(">>>> FlutterPcmSound feed callback disabled, buffer cleared.");
}


void _handleEncryptedAudioData(Uint8List encryptedData) {
  // print(">>>> Handling encrypted audio data: ${encryptedData.length} bytes");
  if (_sharedKey == null) {
    print("!!!! Decrypt Error: Shared key is null.");
    return;
  }
  // ... (decryption setup remains the same) ...
  try {
    final nonce = encryptedData.sublist(0, gcmNonceLengthBytes);
    final ciphertextWithTag = encryptedData.sublist(gcmNonceLengthBytes);

    final cipher = pc.GCMBlockCipher(pc.AESFastEngine());
    final params = pc.AEADParameters(
        pc.KeyParameter(_sharedKey!), gcmTagLengthBits, nonce, Uint8List(0));
    cipher.init(false, params); // False for decryption

    Uint8List decryptedBytes = cipher.process(ciphertextWithTag);

    // --- CONVERSION STEP ---
    if (decryptedBytes.isNotEmpty) {
      // Convert Uint8List (bytes) to List<int> (int16 samples)
      // Assumes 16-bit Little Endian PCM data, which is common. Verify if your source is different.
      List<int> pcmSamples = [];
      ByteData byteData = ByteData.view(decryptedBytes.buffer, decryptedBytes.offsetInBytes, decryptedBytes.lengthInBytes);
      for (int i = 0; i < decryptedBytes.lengthInBytes; i += 2) {
        // Read two bytes as a signed 16-bit integer (little-endian)
        pcmSamples.add(byteData.getInt16(i, Endian.little));
      }

      
      if (pcmSamples.isNotEmpty) {
         _audioBuffer.add(pcmSamples);
        //  print(">>>> PCM Chunk (${pcmSamples.length} samples) added to buffer. Size: ${_audioBuffer.length}.");

         // --- IMPORTANT: NO DIRECT PLAYBACK TRIGGER ---
         // We no longer call _playNextChunkFromBuffer() here.
         // The _onFeedPcmSound callback will automatically pull data
         // from _audioBuffer when FlutterPcmSound needs it.

         // --- Start playback if it hasn't started yet ---
         // This ensures playback begins once the first chunk arrives.
         if (!_isPcmSoundPlaying && _isAudioInitialized) {
            print(">>>> First audio chunk received, starting FlutterPcmSound playback.");
            _startPcmSoundPlayback();
            _onFeedPcmSound(0);
         }

      } else {
         print(">>>> Decryption resulted in empty PCM samples after conversion, discarding.");
      }

    } else {
       print(">>>> Decryption resulted in empty byte data, discarding.");
    }

  } on pc.InvalidCipherTextException catch (e) {
    print("!!!! Decryption failed (InvalidCipherTextException): Authentication tag check failed. $e");
  } catch (e, s) {
    print("!!!! Decryption or Conversion/Buffer Add failed: $e");
    print("!!!! Stack trace: $s");
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
    _stopPcmSoundPlayback();
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

  // --- Core Call Logic Reset ---
  bool wasInCall = _isInCall; // Keep track if we were actually in a call
  _queuedWebRTCSignals.clear(); // Clear any pending WebRTC signals
  _isInCall = false; // Mark as not in call
  _remoteUserId = null; // Forget the remote user

  // --- QKD State Reset ---
  _qkdSimulator?.reset(); // Reset the simulator if it exists
  _qkdSimulator = null;
  _sharedKey = null; // Clear the derived key
  _qkdState = QkdState.idle; // Set QKD state back to idle

  // --- Audio State Reset (within mounted check) ---
  if (mounted) {
    setState(() {
      // Preserve specific end-call statuses
      bool hadError = _callStatus.contains("Error") || _callStatus.contains("Failed") || _callStatus.contains("Permission");
      bool wasDisconnected = _callStatus.contains("disconnect") || _callStatus.contains("Lost");
      bool wasEnded = _callStatus.contains("ended by");
      bool wasRejected = _callStatus.contains("rejected");

      // Only reset status to 'Ready' if the call ended normally or wasn't really active
      if (!wasInCall || (!hadError && !wasDisconnected && !wasEnded && !wasRejected)) {
        _callStatus = 'Ready'; // Reset call status message
      } else {
        print(">>>> Preserving call status: $_callStatus");
        // Otherwise, keep the existing status (e.g., "Call ended by peer", "Connection Error")
      }

      // --- Flags related to media ---
      _isRecording = false; // Ensure recording flag is false (stopMicStream should have handled the actual stop)

      // ADDED/MODIFIED: Reset both PCM playback state and UI state flag
      _isPcmSoundPlaying = false;
      _isPlayingAudio = false;

    });
  } else {
    // If not mounted, just update the variables directly
    // Note: _callStatus preservation logic doesn't apply if not mounted
    _callStatus = 'Ready'; // Or perhaps leave it as it was? Depends on desired behavior.
    _isRecording = false;
    _isPcmSoundPlaying = false; // ADDED
    _isPlayingAudio = false;    // MODIFIED
  }

  print(">>>> Call state reset complete. InCall: $_isInCall, Status: $_callStatus, PcmPlaying: $_isPcmSoundPlaying");
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
                        _isPcmSoundPlaying
                            ? Icons.graphic_eq
                            : Icons.volume_mute,
                        color: _isPcmSoundPlaying ? Colors.blue : Colors.grey,
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