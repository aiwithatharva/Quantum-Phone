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
const int recordSampleRate = 16000; // Keep consistent

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
  bool _isTransmitting = false; // User is holding the 'Talk' button
  bool _remoteIsTransmitting = false; // Remote user is holding 'Talk' button

  // Networking
  WebSocketChannel? _channel;
  final String _webSocketUrl = 'ws://ec2-18-212-33-85.compute-1.amazonaws.com:8080'; // Replace with your actual URL

  // WebRTC
  RTCPeerConnection? _peerConnection;
  RTCDataChannel? _dataChannel;
  RTCDataChannel? _remoteDataChannel;
  MediaStream? _localStream; // Not used for audio in this version
  MediaStream? _remoteStream; // Not used for audio in this version

  final Map<String, dynamic> _rtcConfiguration = {
    'iceServers': [
      {'urls': 'stun:stun.l.google.com:19302'},
      {'urls': 'stun:stun1.l.google.com:19302'},
      {'urls': 'stun:stun2.l.google.com:19302'},
    ],
    'sdpSemantics': 'unified-plan', // Ensure this matches your backend/peer
  };

  // QKD
  QkdState _qkdState = QkdState.idle;
  BB84Simulator? _qkdSimulator;
  Uint8List? _sharedKey;

  // Audio Handling (Using record plugin for capture, FlutterPcmSound for playback)
  late AudioRecorder _audioRecorder;
  StreamSubscription<RecordState>? _recordStateSubscription;
  StreamSubscription<Amplitude>? _amplitudeSubscription; // Can be used for VU meter if needed
  StreamSubscription<Uint8List>? _audioChunkSubscription; // Captures PCM chunks

  bool _isAudioInitialized = false; // For FlutterPcmSound setup
  bool _isSpeakerphoneOn = false; // Kept for potential future use, but less critical now
  bool _isPcmSoundPlaying = false; // Tracks if the playback engine is active
  final Queue<List<int>> _audioBuffer = Queue<List<int>>(); // Buffer for received audio samples
  bool _isPlayingAudio = false; // UI State: Is audio actually coming out?


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
      // We manage _isTransmitting via button press/release, not directly from recorder state.
      // However, it's useful for debugging.
      if (recordState == RecordState.stop && mounted && _isTransmitting) {
        print(">>>> Recorder stopped unexpectedly while _isTransmitting was true. Resetting.");
        // This might happen if something external stops the recording
        setStateIfMounted(() {
           _isTransmitting = false;
        });
        // Consider sending 'stopTalking' signal if this happens unexpectedly
        if (_remoteUserId != null) {
           _sendMessage({
               'action': 'stopTalking',
               'toId': _remoteUserId!,
               'fromId': _myId,
           });
        }
      }
    }, onError: (e) {
      print("!!!! Recorder state error: $e");
      setStateIfMounted(() {
        _isTransmitting = false; // Ensure state is reset on error
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
          ">>>> App paused/inactive/detached/hidden. Stopping media if active.");
      if (_isTransmitting) {
         _stopMicAndSignal(); // Stop recording and notify peer
      }
      if (_isPcmSoundPlaying) {
         _stopPcmSoundPlayback();
      }
    }
  }

   // Helper to stop mic and send signal, used on release and app pause
  Future<void> _stopMicAndSignal() async {
    if (!_isTransmitting) return; // Already stopped

    print(">>>> Stopping Mic and Signaling Stop");
    await _stopMicStream(); // Stop recording first
    setStateIfMounted(() => _isTransmitting = false);
    if (_remoteUserId != null && _channel != null && _channel!.closeCode == null) {
       _sendMessage({
           'action': 'stopTalking',
           'toId': _remoteUserId!,
           'fromId': _myId,
       });
    }
  }


  @override
  void dispose() {
    print(">>>> DialerScreen disposing...");
    WidgetsBinding.instance.removeObserver(this);
    _channel?.sink.close(1000, "Client disposed");
    _closeWebRTCSession(notifyServer: false); // Ensure cleanup

    _recordStateSubscription?.cancel();
    _amplitudeSubscription?.cancel();
    _audioRecorder.dispose();
    _audioChunkSubscription?.cancel();

    print(">>>> Releasing FlutterPcmSound resources...");
    FlutterPcmSound.release();

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
     if (mounted) {
         setState(() {
           _connectionStatus = 'Connecting...';
         });
     }
     try {
       _channel = WebSocketChannel.connect(Uri.parse(_webSocketUrl));
       print(">>>> WebSocket channel created. Setting up listeners...");
       if (mounted) {
           setState(() {
             _connectionStatus = 'Connected (Registering...)';
           });
       }

       _sendMessage({'action': 'register', 'userId': _myId});

       _channel!.stream.listen(
         (dynamic message) {
           _handleServerMessage(message);
         },
         onDone: _handleWebSocketDone,
         onError: _handleWebSocketError,
         cancelOnError: true, // Important: Stop listening on error
       );
     } catch (e, s) {
       print("!!!! WebSocket connection exception: $e");
       print("!!!! Stack trace: $s");
       _handleWebSocketError(e); // Trigger the error handling logic
     }
   }


  void _sendMessage(Map<String, dynamic> message) {
    if (_channel != null && _channel!.closeCode == null) {
      final jsonMessage = jsonEncode(message);
      // Reduce logging noise for frequent messages if needed
      // if (message['action'] != 'webrtcSignal' && message['action'] != 'qkdMessage') {
           print(">>>> WebSocket sending: Action: ${message['action']}, To: ${message['toId'] ?? 'N/A'}");
      // }
      _channel!.sink.add(jsonMessage);
    } else {
      print("!!!! WebSocket cannot send message: Channel is null or closed. Status: ${_connectionStatus}, Close Code: ${_channel?.closeCode}");
      if (mounted && !_connectionStatus.contains('Error')) {
          setState(() {
            _connectionStatus = 'Error (Send Failed)';
            if (_isInCall) _callStatus = 'Connection Error';
          });
          // Consider attempting reconnect or closing session fully
          _closeWebRTCSession(notifyServer: false);
      }
    }
  }

  void _handleWebSocketDone() {
    print(
        "!!!! WebSocket disconnected (onDone). Close code: ${_channel?.closeCode}, Reason: ${_channel?.closeReason}");
    if (mounted) {
      setState(() {
        _connectionStatus = 'Disconnected';
        if (_isInCall) _callStatus = 'Connection Lost'; // Update call status if in call
      });
      if (_isInCall) {
        print(">>>> WebSocket disconnected during call, closing WebRTC session.");
        _closeWebRTCSession(notifyServer: false); // Clean up WebRTC state
      }
    }
    _channel = null; // Ensure channel is nullified
  }

  void _handleWebSocketError(dynamic error, [StackTrace? stackTrace]) {
    print('!!!! WebSocket error: $error');
    if (stackTrace != null) {
      print('!!!! Stack trace: $stackTrace');
    }
    if (mounted) {
      setState(() {
        _connectionStatus = 'Error';
         if (_isInCall) _callStatus = 'Connection Error';
      });
      if (_isInCall) {
        print(">>>> WebSocket error during call, closing WebRTC session.");
        _closeWebRTCSession(notifyServer: false);
      }
    }
     // Attempt to close sink gracefully, though it might already be closed
     _channel?.sink.close(1011, "WebSocket Error").catchError((e) {
       print(">>>> Error closing WebSocket sink after error: $e");
     });
    _channel = null;
  }

  // --- Server Message Handler & Action Handlers ---
  void _handleServerMessage(dynamic message) {
    if (!mounted) return;
    if (message is String) {
      try {
        final decodedMessage = jsonDecode(message) as Map<String, dynamic>;
        final action = decodedMessage['action'] as String?;
        final fromId = decodedMessage['fromId'] as String? ??
            decodedMessage['relayedFrom'] as String?; // Check both fields
        final data = decodedMessage['data'];

        print(">>>> Handling server message: Action: $action, From: $fromId");

        switch (action) {
          case 'startTalking': // Remote user pressed their button
            if (fromId == _remoteUserId) {
              print(">>>> Received 'startTalking' from $_remoteUserId");
              setStateIfMounted(() {
                _remoteIsTransmitting = true;
                // Stop local playback if it was happening
                if(_isPcmSoundPlaying) _stopPcmSoundPlayback();
                _callStatus = 'Receiving from $_remoteUserId...';
              });
            }
            break;

          case 'stopTalking': // Remote user released their button
            if (fromId == _remoteUserId) {
              print(">>>> Received 'stopTalking' from $_remoteUserId");
              setStateIfMounted(() {
                _remoteIsTransmitting = false;
                // Check if the connection is still good for the status update
                 if (_peerConnection?.connectionState == RTCPeerConnectionState.RTCPeerConnectionStateConnected) {
                    _callStatus = 'Securely Connected'; // Or 'Ready to Talk'
                 }
              });
              // Playback will start automatically via _handleEncryptedAudioData if needed
            }
            break;
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
               print("!!!! Invalid QKD message data format: Expected Map<String, dynamic>, got ${data?.runtimeType}");
            }
            break;
          case 'webrtcSignal':
             if (data is Map<String, dynamic>) {
              _handleWebRTCSignalAction(fromId, data);
            } else {
               print("!!!! Invalid WebRTC signal data format: Expected Map<String, dynamic>, got ${data?.runtimeType}");
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
      print('!!!! Received non-string message from WebSocket: ${message.runtimeType}');
    }
  }

  // --- Specific Action Handlers (mostly unchanged, focus on signaling ones above) ---
   void _handleIncomingCallAction(String? fromId) {
     if (fromId == null) return;
     if (_isInCall) {
       print("!!!! Ignoring incoming call from $fromId while already in a call with $_remoteUserId.");
       _sendCallResponse(fromId, false); // Busy
       return;
     }
     print(">>>> Handling incoming call from $fromId");
     setStateIfMounted(() {
       _remoteUserId = fromId; // Tentatively set remote user
       _callStatus = 'Incoming call from $fromId';
     });
     _showIncomingCallDialog(fromId);
   }

  void _handleCallStatusAction(String? fromId, Map<String, dynamic> decodedMessage) {
    final accepted = decodedMessage['accepted'] as bool?;
    print(">>>> Handling call status from $fromId: Accepted: $accepted");
    if (fromId == _remoteUserId) { // Check if it's for the user we are calling
      if (accepted == true) {
        setStateIfMounted(() {
          _callStatus = 'Call accepted by $fromId. Starting QKD...';
          // _isInCall was already set true when initiating
        });
        _startQkdProcess(isInitiator: true);
      } else {
        setStateIfMounted(() {
          _callStatus = 'Call with $fromId rejected.';
        });
        _resetCallState(); // Reset completely if rejected
      }
    } else {
      print("!!!! Received call status for an unexpected remote user: $fromId (current: $_remoteUserId)");
    }
  }

   void _handleQkdMessageAction(String? fromId, Map<String, dynamic> qkdData) {
     print(">>>> Handling QKD message from $fromId. Current state: $_qkdState");
     if (fromId == _remoteUserId && _qkdSimulator != null && _qkdState == QkdState.exchanging) {
       print(">>>> Passing QKD data to simulator: Type: ${qkdData['type']}");
       _qkdSimulator!.processSignal(qkdData);
     } else {
       print("!!!! Ignoring QKD message: ID mismatch ($fromId vs $_remoteUserId), null simulator, or wrong state ($_qkdState).");
     }
   }

   void _handleWebRTCSignalAction(String? fromId, Map<String, dynamic> webrtcData) {
     print(">>>> Handling WebRTC signal wrapper from $fromId. QKD State: $_qkdState");
     if (fromId == _remoteUserId && _qkdState == QkdState.success) {
       _handleWebRTCSignal(webrtcData); // Pass the inner data
     } else if (fromId == _remoteUserId && _qkdState != QkdState.success && _peerConnection == null) {
        // QKD not done yet, but we might be setting up WebRTC soon. Queue it.
        print(">>>> QKD not successful yet, but queuing WebRTC signal from $fromId.");
        _queuedWebRTCSignals.add(webrtcData);
     } else {
        print("!!!! Ignoring WebRTC signal: ID mismatch ($fromId vs $_remoteUserId) or QKD not successful ($_qkdState) or unexpected state.");
     }
   }


  void _handleCallEndedAction(String? fromId) {
    print(">>>> Handling call ended message from $fromId.");
    if (fromId == _remoteUserId) {
      setStateIfMounted(() {
        _callStatus = 'Call ended by $fromId.';
      });
      _closeWebRTCSession(notifyServer: false); // Clean up without notifying back
    } else {
      print("!!!! Received call ended message for unexpected remote user: $fromId (current: $_remoteUserId)");
    }
  }

  void _handleCallErrorAction(Map<String, dynamic> decodedMessage) {
    final reason = decodedMessage['reason'] ?? 'Unknown error';
    print("!!!! Handling call error message: $reason");
    setStateIfMounted(() {
      _callStatus = 'Call Error: $reason';
    });
    _closeWebRTCSession(notifyServer: false); // Clean up on error
  }


  // --- Call Control UI ---
  Future<void> _showIncomingCallDialog(String fromId) async {
    print(">>>> Showing incoming call dialog for $fromId");
    // Ensure previous dialogs are dismissed if any race conditions occur
    if (Navigator.of(context).canPop()) {
       Navigator.of(context).pop();
    }
    return showDialog<void>(
        context: context,
        barrierDismissible: false, // User must accept or reject
        builder: (BuildContext context) {
          return AlertDialog(
            title: const Text('Incoming Call'),
            content: Text('Call from ID: $fromId'),
            actions: <Widget>[
              TextButton(
                  child: const Text('Reject'),
                  onPressed: () {
                    print(">>>> Incoming call rejected by user.");
                    Navigator.of(context).pop(); // Close dialog
                    _sendCallResponse(fromId, false);
                    setStateIfMounted(() {
                      _callStatus = 'Rejected call from $fromId';
                      _remoteUserId = null; // Clear remote user since rejected
                    });
                  }),
              TextButton(
                  child: const Text('Accept'),
                  onPressed: () {
                    print(">>>> Incoming call accepted by user.");
                    Navigator.of(context).pop(); // Close dialog
                    _sendCallResponse(fromId, true);
                    setStateIfMounted(() {
                       _callStatus = 'Accepted call from $fromId. Starting QKD...';
                       _isInCall = true; // Now we are in a call
                       _remoteUserId = fromId; // Confirmed remote user
                    });
                    _startQkdProcess(isInitiator: false); // Start QKD as Bob
                  }),
            ],
          );
        });
  }

  void _sendCallResponse(String originalCallerId, bool accepted) {
    print(">>>> Sending call response to $originalCallerId: Accepted: $accepted");
    _sendMessage({
      'action': 'callResponse',
      'toId': originalCallerId,
      'fromId': _myId, // My ID is the responder
      'accepted': accepted
    });
  }

  void _initiateSecureCall() {
    final String targetId = _enteredNumber;
    print(">>>> Initiate secure call button pressed. Target: $targetId");

    if (!_connectionStatus.startsWith('Registered')) {
       ScaffoldMessenger.of(context).showSnackBar(
           const SnackBar(content: Text('Not connected. Trying to reconnect...')));
       _connectWebSocket(); // Try to reconnect
       return;
    }
    if (_isInCall) {
       ScaffoldMessenger.of(context)
           .showSnackBar(const SnackBar(content: Text('Already in a call.')));
       return;
    }
    if (targetId.isNotEmpty && targetId.length == 10) {
      if (targetId == _myId) {
         ScaffoldMessenger.of(context)
             .showSnackBar(const SnackBar(content: Text('Cannot call yourself.')));
         return;
      }
      print(">>>> Requesting secure call from $_myId to target ID: $targetId");
      setStateIfMounted(() {
        _callStatus = 'Calling $targetId...';
        _isInCall = true; // Mark as in call process
        _remoteUserId = targetId; // Set the target user
      });
      _sendMessage({
         'action': 'callRequest',
         'toId': targetId,
         'fromId': _myId
      });
    } else {
      ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Please enter a valid 10-digit ID.')));
    }
  }

  void _hangUp() {
    print(">>>> Hang Up button pressed or initiated internally.");
    _closeWebRTCSession(notifyServer: true); // Close session and notify server
  }

  // --- QKD Process (Unchanged) ---
  void _startQkdProcess({required bool isInitiator}) {
    if (_qkdState != QkdState.idle) {
      print("!!!! QKD process already started or not idle ($_qkdState). Ignoring request.");
      return;
    }
    print(">>>> Starting QKD Process (Role: ${isInitiator ? 'Alice' : 'Bob'})");
    setStateIfMounted(() {
      _qkdState = QkdState.exchanging;
      _callStatus = "Exchanging quantum keys...";
      _sharedKey = null; // Ensure key is nullified before exchange
    });

    // Ensure remoteUserId is set before starting QKD
    if (_remoteUserId == null) {
       print("!!!! Cannot start QKD: remoteUserId is null.");
       setStateIfMounted(() {
          _callStatus = "Error: Remote user not set.";
          _qkdState = QkdState.failed;
       });
       _resetCallState();
       return;
    }

    _qkdSimulator = BB84Simulator(
      keyLength: 2048, // Or your desired length
      isAlice: isInitiator,
      sendSignal: _sendQkdMessage, // Callback to send via WebSocket
      onKeyDerived: _handleKeyDerived, // Callback for result
    );
    _qkdSimulator!.startExchange(); // Start the BB84 protocol
  }

  void _sendQkdMessage(Map<String, dynamic> qkdData) {
    if (_remoteUserId != null && _qkdState == QkdState.exchanging) {
      print(">>>> Sending QKD message (Type: ${qkdData['type']}) to $_remoteUserId");
      _sendMessage({
        'action': 'qkdMessage',
        'toId': _remoteUserId!,
        'fromId': _myId,
        'data': qkdData // The actual QKD payload
      });
    } else {
      print("!!!! Cannot send QKD message: No remote user or not in exchanging state ($_qkdState).");
      // Handle potential error state if QKD fails due to this
      if (_qkdState == QkdState.exchanging) {
         _handleKeyDerived(null); // Simulate failure
      }
    }
  }

  void _handleKeyDerived(Uint8List? derivedKey) {
    print(">>>> QKD Simulator finished. Result received.");
    // Check if we are still in the exchanging state and mounted
    if (!mounted || _qkdState != QkdState.exchanging) {
      print("!!!! Ignoring QKD result: Widget not mounted or state is not 'exchanging' ($_qkdState).");
      _qkdSimulator = null; // Clean up simulator instance
      return;
    }

    if (derivedKey != null && derivedKey.length >= BB84Simulator.minFinalKeyLengthBytes) {
      print(">>>> QKD SUCCESS! Derived key length: ${derivedKey.length} bytes.");
      setStateIfMounted(() {
        _sharedKey = derivedKey; // Store the key
        _qkdState = QkdState.success;
        _callStatus = "Key exchange complete. Connecting media...";
      });
      print(">>>> Proceeding to start WebRTC session...");
      // Determine initiator based on the simulator role
      _startWebRTCSession(isInitiator: _qkdSimulator?.isAlice ?? false);
    } else {
      print("!!!! QKD FAILED! Derived key is null or too short (${derivedKey?.length ?? 'null'} bytes).");
      setStateIfMounted(() {
        _sharedKey = null;
        _qkdState = QkdState.failed;
        _callStatus = "Key exchange failed. Call aborted.";
      });
      _hangUp(); // Abort the call on QKD failure
    }
    _qkdSimulator = null; // Clean up simulator instance after completion/failure
  }


  // --- WebRTC Session Setup (Mostly Unchanged, ensure data channel is configured correctly) ---
  Future<void> _startWebRTCSession({required bool isInitiator}) async {
     print(">>>> Entering _startWebRTCSession (Initiator: $isInitiator)");
     if (_qkdState != QkdState.success || _sharedKey == null) {
       print("!!!! Cannot start WebRTC: QKD not successful or key is null.");
       _resetCallState(); // Abort if QKD failed before this step
       return;
     }
     if (_peerConnection != null) {
       print("!!!! Cannot start WebRTC: PeerConnection already exists.");
       return; // Avoid re-creating
     }

     print(">>>> Requesting permissions for WebRTC (Microphone)...");
     if (!await _requestPermissions()) {
       print("!!!! Permission denied for WebRTC.");
       setStateIfMounted(() => _callStatus = "Microphone Permission Denied");
       _resetCallState();
       return;
     }
     print(">>>> Permissions granted.");

     // Initialize audio playback system if not already done
     if (!_isAudioInitialized) {
       print(">>>> Audio playback not initialized, initializing now...");
       await _initializePcmSound();
       if (!_isAudioInitialized) {
           print("!!!! Failed to initialize audio playback. Aborting call.");
           setStateIfMounted(() => _callStatus = "Audio Playback Init Failed");
           _resetCallState();
           return;
       }
     }

     print(">>>> Creating RTCPeerConnection...");
     try {
       _peerConnection = await createPeerConnection(_rtcConfiguration);
       if (_peerConnection == null) {
         throw Exception("createPeerConnection returned null");
       }
       print(">>>> RTCPeerConnection created successfully.");

       print(">>>> Setting up PeerConnection listeners...");
       _setupPeerConnectionListeners(); // Moved listener setup to separate function

       print(">>>> Creating local DataChannel 'audioChannel'...");
       // Configure Data Channel: Ordered and Reliable (maxRetransmits=0 means unreliable, use null or remove for reliable)
       RTCDataChannelInit dataChannelDict = RTCDataChannelInit()
         ..ordered = true; // Ensure messages arrive in order
         // ..maxRetransmits = null; // Use default for reliable transmission (or omit)

       _dataChannel = await _peerConnection!.createDataChannel('audioChannel', dataChannelDict);
       if (_dataChannel == null) {
         throw Exception("createDataChannel returned null");
       }
       print(">>>> Local DataChannel created: Label: ${_dataChannel!.label}, ID: ${_dataChannel!.id}, State: ${_dataChannel!.state}");
       _setupDataChannelListeners(_dataChannel!); // Setup listeners for the local channel

       // Process any signals that arrived before PC was ready
        await _processQueuedSignals();

       if (isInitiator) {
         print(">>>> Initiator creating Offer...");
         // No need to offer audio/video tracks in SDP for data-only channel
         RTCSessionDescription offer = await _peerConnection!.createOffer(); // Simpler offer
         print(">>>> Offer created. Setting local description...");
         await _peerConnection!.setLocalDescription(offer);
         print(">>>> Local description set. Sending offer...");
         _sendWebRTCSignal(offer.toMap());
       } else {
         print(">>>> Receiver waiting for Offer...");
         // Offer will be handled by _handleWebRTCSignal when it arrives
       }

     } catch (e, s) {
       print("!!!! Error starting WebRTC session: $e");
       print("!!!! Stack trace: $s");
       setStateIfMounted(() {
         _callStatus = "WebRTC Error: ${e.toString().substring(0, min(e.toString().length, 50))}";
       });
       _closeWebRTCSession(notifyServer: true); // Clean up on error
     }
   }

  void _setupPeerConnectionListeners() {
     _peerConnection!.onIceCandidate = (candidate) {
       if (candidate != null) {
          print(">>>> ICE Candidate generated: ${candidate.candidate?.substring(0, min(30, candidate.candidate?.length ?? 0))}...");
          _sendWebRTCSignal({'type': 'candidate', 'candidate': candidate.toMap()});
       } else {
         print(">>>> End of ICE candidates signaled.");
       }
     };

     _peerConnection!.onIceConnectionState = (state) {
       print(">>>> ICE Connection State changed: $state");
       setStateIfMounted(() {
         // Update status based on ICE state if needed, e.g., connecting, failed
         switch (state) {
            case RTCIceConnectionState.RTCIceConnectionStateChecking:
              if (_callStatus == "Key exchange complete. Connecting media...") {
                 _callStatus = "Connecting (ICE)...";
              }
              break;
            case RTCIceConnectionState.RTCIceConnectionStateConnected:
            case RTCIceConnectionState.RTCIceConnectionStateCompleted:
              // Don't set to 'Connected' here, wait for DataChannel/PeerConnection state
              break;
            case RTCIceConnectionState.RTCIceConnectionStateFailed:
              print('!!!! ICE Connection Failed !!!!');
              if (_isInCall) _callStatus = 'Connection Failed (ICE)';
              _closeWebRTCSession(notifyServer: true);
              break;
            case RTCIceConnectionState.RTCIceConnectionStateDisconnected:
               if (_isInCall) _callStatus = 'Temporarily Disconnected (ICE)';
               // WebRTC might recover, don't hang up immediately unless it stays disconnected
               break;
            case RTCIceConnectionState.RTCIceConnectionStateClosed:
               // Already handled by PeerConnection state or hangup
               break;
             default:
              break;
         }
       });
     };

     _peerConnection!.onConnectionState = (state) {
       print('>>>> PeerConnection State changed: $state');
        setStateIfMounted(() {
           switch(state) {
               case RTCPeerConnectionState.RTCPeerConnectionStateConnected:
                  print(">>>> PeerConnection CONNECTED.");
                  // Set status only if Data Channel is also open or opening
                  if (_dataChannel?.state == RTCDataChannelState.RTCDataChannelOpen || _remoteDataChannel?.state == RTCDataChannelState.RTCDataChannelOpen) {
                     _callStatus = 'Securely Connected';
                  } else {
                     _callStatus = 'Peer Connected, Data Pending...';
                  }
                  break;
               case RTCPeerConnectionState.RTCPeerConnectionStateFailed:
                  print("!!!! PeerConnection FAILED !!!!");
                  if (_isInCall) _callStatus = 'Connection Failed (Peer)';
                  _closeWebRTCSession(notifyServer: true);
                  break;
               case RTCPeerConnectionState.RTCPeerConnectionStateDisconnected:
               case RTCPeerConnectionState.RTCPeerConnectionStateClosed:
                   print("!!!! PeerConnection Disconnected or Closed.");
                   // Don't reset status if it was already "ended by" etc.
                   if (_isInCall && !(_callStatus.contains("ended by") || _callStatus.contains("rejected") || _callStatus.contains("Failed"))) {
                     _callStatus = 'Call disconnected.';
                   }
                   // Close session fully if not already triggered by hangup
                   if (_isInCall) {
                       _closeWebRTCSession(notifyServer: false); // Clean up locally
                   }
                   break;
               default:
                  // Handle other states like 'connecting' if needed
                  break;
           }
        });
     };

     _peerConnection!.onIceGatheringState = (state) {
       print('>>>> ICE Gathering State changed: $state');
       // Can be used for debugging
     };

     // Listener for when the remote peer adds a data channel
     _peerConnection!.onDataChannel = (channel) {
       print(">>>> Remote DataChannel received: Label: ${channel.label}, ID: ${channel.id}, State: ${channel.state}");
       _remoteDataChannel = channel;
       _setupDataChannelListeners(_remoteDataChannel!); // Setup listeners for the remote channel
     };
  }


  void _setupDataChannelListeners(RTCDataChannel channel) {
    print(">>>> Setting up listeners for DataChannel: Label: ${channel.label}, ID: ${channel.id}");
    channel.onDataChannelState = (state) {
      print(">>>> DataChannel State (${channel.label}, ID: ${channel.id}): $state");
      setStateIfMounted(() {
         if (state == RTCDataChannelState.RTCDataChannelOpen) {
           print(">>>> DataChannel OPEN! (${channel.label}, ID: ${channel.id}). Ready for Push-to-Talk.");
           // Reset transmission states when channel opens/re-opens
           _isTransmitting = false;
           _remoteIsTransmitting = false;
           // Set status to connected only if PeerConnection is also connected
           if (_peerConnection?.connectionState == RTCPeerConnectionState.RTCPeerConnectionStateConnected) {
              _callStatus = 'Securely Connected'; // Final connected state
           } else {
              _callStatus = 'Data Channel Open, Peer Pending...';
           }
         } else if (state == RTCDataChannelState.RTCDataChannelClosed) {
           print("!!!! DataChannel CLOSED! (${channel.label}, ID: ${channel.id})");
           // If either channel closes unexpectedly during a call, treat it as a disconnect
           if (_isInCall && !(_callStatus.contains("ended by") || _callStatus.contains("rejected") || _callStatus.contains("Failed"))) {
              _callStatus = 'Data Channel Closed.';
              _closeWebRTCSession(notifyServer: false); // Clean up session
           }
         } else if (state == RTCDataChannelState.RTCDataChannelClosing) {
           print(">>>> DataChannel Closing (${channel.label}, ID: ${channel.id})");
         } else if (state == RTCDataChannelState.RTCDataChannelConnecting) {
           print(">>>> DataChannel Connecting (${channel.label}, ID: ${channel.id})");
           if (_callStatus.contains("Connecting") || _callStatus.contains("Key exchange complete") ) {
              _callStatus = "Connecting (Data Channel)...";
           }
         }
      });
    };

    channel.onMessage = (RTCDataChannelMessage message) {
       // print(">>>> DataChannel (${channel.label}, ID: ${channel.id}) Received message.");
       if (message.isBinary) {
         // This is where encrypted audio chunks arrive
         _handleEncryptedAudioData(message.binary);
       } else {
         // Could be used for other signaling if needed in the future
         print("!!!! Received non-binary message on data channel: ${message.text}");
       }
    };
    // Note: There is no distinct onError callback for RTCDataChannel in flutter_webrtc
  }

  Future<void> _handleWebRTCSignal(Map<String, dynamic> signal) async {
    final type = signal['type'] as String?;
    print(">>>> Handling received WebRTC signal (Type: $type)");

    // Queue signal if PeerConnection isn't ready yet (essential for handling signals arriving early)
    if (_peerConnection == null) {
        print("!!!! PeerConnection is null. Queueing signal (Type: $type).");
        _queuedWebRTCSignals.add(signal);
        return;
    }

    // Double-check QKD state if needed, although primary check is in _handleWebRTCSignalAction
    if (_qkdState != QkdState.success) {
      // This might happen if QKD fails *after* WebRTC setup started but before PC is fully ready
      print("!!!! WebRTC signal ($type) arrived but QKD state is now $_qkdState. Ignoring.");
      // Optionally queue it anyway? Depends on recovery strategy. For now, ignore.
      // _queuedWebRTCSignals.add(signal);
      return;
    }

    try {
        final remoteDescriptionExists = (await _peerConnection!.getRemoteDescription()) != null;

        switch (type) {
          case 'offer':
            print(">>>> Handling OFFER signal...");
            if (_peerConnection!.signalingState != RTCSignalingState.RTCSignalingStateStable &&
                _peerConnection!.signalingState != RTCSignalingState.RTCSignalingStateHaveRemoteOffer) { // Check for glare potential
              print("!!!! Received Offer in unexpected state: ${_peerConnection!.signalingState}. Potential glare? Handling anyway.");
              // Basic glare resolution: If we are initiator and get offer, maybe ignore or renegotiate?
              // For simplicity now, we process it. A more robust app might need role-based logic.
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

             // After setting remote offer and local answer, process queued candidates
             await _processQueuedSignals();
            break;

          case 'answer':
            print(">>>> Handling ANSWER signal...");
            if (_peerConnection!.signalingState != RTCSignalingState.RTCSignalingStateHaveLocalOffer) {
               print("!!!! Received Answer in unexpected state: ${_peerConnection!.signalingState}.");
               // Ignore if we didn't send an offer?
               if (_peerConnection!.signalingState == RTCSignalingState.RTCSignalingStateStable) {
                  print("!!!! Ignoring unexpected Answer.");
                  return;
               }
            }
            print(">>>> Setting remote description (Answer)...");
            await _peerConnection!.setRemoteDescription(
                RTCSessionDescription(signal['sdp'], signal['type']));
            print(">>>> Remote description (Answer) set.");

             // After setting remote answer, process queued candidates
             await _processQueuedSignals();
            break;

          case 'candidate':
             print(">>>> Handling CANDIDATE signal...");
             final candidateData = signal['candidate'];
             if (candidateData is Map<String, dynamic>) {
                final candidate = RTCIceCandidate(
                  candidateData['candidate'] as String? ?? '',
                  candidateData['sdpMid'] as String?,
                  candidateData['sdpMLineIndex'] as int?,
                );

               // IMPORTANT: Only add candidate if remote description is set. Queue otherwise.
                if (remoteDescriptionExists) {
                   print(">>>> Adding ICE Candidate (remote description exists)...");
                   await _peerConnection!.addCandidate(candidate);
                   print(">>>> ICE Candidate added.");
                } else {
                   print("!!!! Received candidate before remote description set. Queueing candidate.");
                   _queuedWebRTCSignals.add(signal); // Re-queue the candidate signal
                }
             } else {
                print("!!!! Invalid candidate format in signal: ${candidateData?.runtimeType}");
             }
             break;
          default:
            print("!!!! Received unknown WebRTC signal type: $type");
        }
    } catch (e, s) {
        print("!!!! Error handling WebRTC signal (Type: $type): $e");
        print("!!!! Stack trace: $s");
        // Consider closing the session on critical errors
        // _closeWebRTCSession(notifyServer: true);
    }
  }


  void _sendWebRTCSignal(Map<String, dynamic> data) {
    if (_remoteUserId != null && _channel != null && _channel!.closeCode == null) {
      // Log type but not full SDP/candidate for brevity
      print(">>>> Sending WebRTC signal (Type: ${data['type']}) to $_remoteUserId");
      _sendMessage({
        'action': 'webrtcSignal',
        'toId': _remoteUserId!,
        'fromId': _myId,
        'data': data // The actual WebRTC payload (offer, answer, candidate)
      });
    } else {
      print("!!!! Cannot send WebRTC signal: remoteUserId is null or WebSocket disconnected.");
      // Handle error state if needed, e.g., close session
    }
  }

  Future<void> _processQueuedSignals() async {
    if (_queuedWebRTCSignals.isEmpty || _peerConnection == null) {
       return; // Nothing to process or PC not ready
    }

    print(">>>> Processing ${_queuedWebRTCSignals.length} queued WebRTC signals...");
    // Create a copy to iterate over, allowing _handleWebRTCSignal to potentially re-queue candidates
    List<Map<String, dynamic>> signalsToProcess = List.from(_queuedWebRTCSignals);
    _queuedWebRTCSignals.clear(); // Clear original queue

    for (final signal in signalsToProcess) {
       final type = signal['type'];
       print(">>>> Processing queued signal (Type: $type)");
       // Re-check conditions before handling
       if (_peerConnection != null && _qkdState == QkdState.success) {
          await _handleWebRTCSignal(signal); // Process it now
       } else {
          print("!!!! Condition changed. Cannot process queued signal ($type). PC: ${_peerConnection != null}, QKD: $_qkdState");
          // Decide whether to re-queue or discard based on why condition changed
          // For now, discard if condition isn't met anymore
       }
    }
    print(">>>> Finished processing initial batch of queued signals.");

    // Check if _handleWebRTCSignal re-queued any signals (likely candidates)
    if (_queuedWebRTCSignals.isNotEmpty) {
       print(">>>> Re-processing newly queued signals (likely candidates)...");
       // Use Future.delayed to avoid potential infinite loop if conditions flip rapidly
       await Future.delayed(Duration(milliseconds: 100));
       await _processQueuedSignals(); // Recursive call to handle re-queued signals
    }
  }

  // --- Audio Capture (Using record), Encryption, Sending ---
  // Starts capturing audio, encrypting chunks, and sending via DataChannel
  Future<void> _startMicStream(RTCDataChannel channel) async {
    // Check conditions before starting
     final bool isRecording = await _audioRecorder.isRecording();
     if (isRecording) {
        print(">>>> Mic stream already recording.");
        return;
     }
    if (!mounted) {
      print("!!!! Cannot start mic stream: Widget not mounted.");
      return;
    }
    if (channel.state != RTCDataChannelState.RTCDataChannelOpen) {
      print("!!!! Attempted to start mic stream but DataChannel state is ${channel.state}");
      return;
    }
    if (_sharedKey == null) {
      print("!!!! Cannot start mic stream: Shared key is null.");
      return;
    }
    print(">>>> Entering _startMicStream for channel ${channel.label}, ID: ${channel.id}");

    // No need to re-request permissions here if already checked in _startWebRTCSession

    try {
      print(">>>> Attempting to start audio stream with 'record' plugin...");
      final stream = await _audioRecorder.startStream(
        const RecordConfig(
          encoder: AudioEncoder.pcm16bits, // Raw PCM data
          sampleRate: recordSampleRate,    // Use consistent rate
          numChannels: 1,                  // Mono
        ),
      );
      print(">>>> Audio stream started successfully via 'record'.");

      // Cancel previous subscription if any exists (safety check)
      await _audioChunkSubscription?.cancel();

      _audioChunkSubscription = stream.listen(
        (audioChunk) {
          // This callback receives raw PCM audio chunks (Uint8List)
          // print(">>>> Audio chunk received: ${audioChunk.length} bytes");
          if (!mounted || !_isTransmitting) { // Check if still mounted AND transmitting
            print("!!!! Audio chunk listener fired but widget not mounted or no longer transmitting. Stopping stream.");
            _stopMicStream(); // Stop if no longer transmitting
            return;
          }
          // Ensure key and channel are still valid
          if (_sharedKey != null && channel.state == RTCDataChannelState.RTCDataChannelOpen) {
             Uint8List? encryptedData = _encryptAudioChunk(audioChunk);
             if (encryptedData != null) {
                // print(">>>> Sending encrypted chunk: ${encryptedData.length} bytes");
                try {
                  // Send the encrypted chunk over the WebRTC data channel
                  channel.send(RTCDataChannelMessage.fromBinary(encryptedData));
                } catch (e) {
                  // Handle potential errors during send (e.g., channel closing)
                  print("!!!! Error sending data channel message: $e");
                  if (e.toString().contains("Closing") || e.toString().contains("Closed")) {
                     print(">>>> Data channel closed during send. Stopping mic stream.");
                     _stopMicStream(); // Stop recording if channel closed
                  }
                  // Could implement buffering/retry logic here if needed
                }
             } else {
                print("!!!! Encryption failed for audio chunk. Skipping send.");
             }
          } else {
             print("!!!! Cannot send audio chunk: Shared key is null or channel state is not Open (${channel.state}). Stopping stream.");
             _stopMicStream(); // Stop if conditions are no longer met
          }
        },
        onError: (e) {
          print("!!!! Audio stream listener error: $e");
          if (mounted && _isTransmitting) {
             setState(() => _isTransmitting = false); // Update state on error
             _stopMicStream(); // Ensure cleanup
             // Send stop signal if error occurs during transmission
              if (_remoteUserId != null) {
                  _sendMessage({
                      'action': 'stopTalking',
                      'toId': _remoteUserId!,
                      'fromId': _myId,
                  });
              }
          }
        },
        onDone: () {
          // This gets called when the stream naturally ends (e.g., recorder stopped)
          print(">>>> Audio stream listener 'onDone' called (stream ended).");
           // Check _isTransmitting flag. If true, it means stop was called externally.
           // If false, it means stop was likely called by user releasing button.
           // We don't need to set _isTransmitting = false here, as it's handled by button release/stopMicStream call.
           _audioChunkSubscription = null; // Clear subscription ref
        },
        cancelOnError: true, // Automatically cancels subscription on error
      );
      print(">>>> Audio stream listener attached.");

    } catch (e, s) {
      print("!!!! Failed to start mic stream using 'record': $e");
      print("!!!! Stack trace: $s");
      if (mounted && _isTransmitting) {
          setState(() => _isTransmitting = false); // Reset state on failure to start
          // Send stop signal if failed to start after signalling start
          if (_remoteUserId != null) {
              _sendMessage({
                  'action': 'stopTalking',
                  'toId': _remoteUserId!,
                  'fromId': _myId,
              });
          }
      }
    }
  }


  // Stops the microphone stream and cancels the subscription
  Future<void> _stopMicStream() async {
    print(">>>> Entering _stopMicStream.");
     // Check if recorder is active first
     final bool isRecording = await _audioRecorder.isRecording();
     print(">>>> Current recorder recording state: $isRecording");

     // Cancel the stream subscription first to prevent further processing
     if (_audioChunkSubscription != null) {
        print(">>>> Cancelling audio chunk subscription...");
        await _audioChunkSubscription!.cancel();
        _audioChunkSubscription = null;
        print(">>>> Audio chunk subscription cancelled.");
     } else {
        print(">>>> Audio chunk subscription already null.");
     }

    // Stop the recorder if it's recording
    if (isRecording) {
       print(">>>> Stopping 'record' recorder...");
       try {
         await _audioRecorder.stop();
         print(">>>> Audio recorder stopped successfully.");
       } catch (e, s) {
         print("!!!! Error stopping 'record' recorder: $e");
         print("!!!! Stack trace: $s");
         // Continue cleanup even if stop fails
       }
    } else {
       print(">>>> Audio recorder was not recording.");
    }

    // The _isTransmitting flag is managed by the button press/release logic,
    // so we don't reset it here directly. It should already be false if stopMicStream
    // was called due to button release.

    print(">>>> Exiting _stopMicStream.");
  }


  // Encrypts a single audio chunk using AES-GCM
  Uint8List? _encryptAudioChunk(Uint8List audioChunk) {
    if (_sharedKey == null || _sharedKey!.length != aesKeyLengthBytes) {
      print("!!!! Encrypt Error: Shared key is null or has incorrect length (${_sharedKey?.length}).");
      return null;
    }

    try {
      // Generate a unique nonce for each encryption operation
      final nonce = _generateSecureNonce();
      if (nonce.length != gcmNonceLengthBytes) {
         print("!!!! Encrypt Error: Generated nonce has incorrect length (${nonce.length}).");
         return null; // Safety check
      }

      // Initialize AES-GCM cipher for encryption
      final cipher = pc.GCMBlockCipher(pc.AESFastEngine());
      // Provide key, tag length (in bits), nonce, and optional associated data (empty here)
      final params = pc.AEADParameters(pc.KeyParameter(_sharedKey!), gcmTagLengthBits, nonce, Uint8List(0));
      cipher.init(true, params); // true for encryption

      // Process the audio chunk to get ciphertext + authentication tag
      Uint8List encryptedChunkWithTag = cipher.process(audioChunk);

      // Prepend the nonce to the encrypted data: Nonce (12 bytes) || Ciphertext + Tag
      final combined = Uint8List(gcmNonceLengthBytes + encryptedChunkWithTag.length);
      combined.setRange(0, gcmNonceLengthBytes, nonce);
      combined.setRange(gcmNonceLengthBytes, combined.length, encryptedChunkWithTag);

      // print(">>>> Encryption successful: Input ${audioChunk.length}, Nonce ${nonce.length}, Output ${combined.length}");
      return combined;
    } catch (e, s) {
      print("!!!! Encryption failed: $e");
      print("!!!! Stack trace: $s");
      return null;
    }
  }

  // Generates a cryptographically secure nonce
  Uint8List _generateSecureNonce() {
    // Using PointyCastle's FortunaRandom for cryptographically secure random bytes
    final secureRandom = pc.FortunaRandom();
    // Seed with entropy from Dart's Random.secure()
    final seedSource = Random.secure();
    final seeds = Uint8List.fromList(List.generate(32, (_) => seedSource.nextInt(256)));
    secureRandom.seed(pc.KeyParameter(seeds));
    // Return the required number of bytes for the nonce
    return secureRandom.nextBytes(gcmNonceLengthBytes);
  }

  // --- Audio Playback (Using FlutterPcmSound), Decryption, Buffering ---

  Future<void> _initializePcmSound() async {
    if (_isAudioInitialized) {
      print(">>>> FlutterPcmSound already initialized.");
      return;
    }
    print(">>>> Initializing FlutterPcmSound...");
    try {
      // Optional: Set log level for debugging
      // FlutterPcmSound.setLogLevel(LogLevel.verbose);

      await FlutterPcmSound.setup(
        sampleRate: recordSampleRate, // Must match sender's rate
        channelCount: 1,             // Mono
      );

      // Set threshold: How much data (in frames) must be fed before playback starts/resumes smoothly.
      // Lower values = lower latency, but more frequent callbacks. Higher = more robust against network jitter.
      // Start with ~100-200ms buffer. (sampleRate / 10) to (sampleRate / 5)
      int feedThreshold = recordSampleRate ~/ 8; // ~125ms buffer
      print(">>>> Setting PCM feed threshold to: $feedThreshold frames");
      await FlutterPcmSound.setFeedThreshold(feedThreshold);

      // Set the callback function that supplies PCM data when needed
      FlutterPcmSound.setFeedCallback(_onFeedPcmSound);

      _isAudioInitialized = true;
      print(">>>> FlutterPcmSound initialized successfully.");

      // Apply initial speakerphone setting if needed (less critical for PTT)
      // await _setSpeakerphone(_isSpeakerphoneOn);

    } catch (e, s) {
      print("!!!! Failed to initialize FlutterPcmSound: $e");
      print("!!!! Stack trace: $s");
      _isAudioInitialized = false;
      // Handle error - maybe disable playback or notify user
      if (mounted) setState(() => _callStatus = "Audio Init Error");
    }
  }

  // Callback triggered by FlutterPcmSound when it needs more audio data
  Future<void> _onFeedPcmSound(int remainingFramesHint) async {
    // This runs frequently during playback. Keep it efficient.
    // print(">>>> _onFeedPcmSound called. Buffer size: ${_audioBuffer.length}, Hint: $remainingFramesHint");

    if (_audioBuffer.isNotEmpty) {
      // Get the next chunk of PCM samples (List<int>) from our buffer
      final List<int> pcmChunk = _audioBuffer.removeFirst();
      // print(">>>> Feeding ${pcmChunk.length} samples. Buffer size now: ${_audioBuffer.length}");

      try {
        // Feed the data to the plugin. It expects PcmArrayInt16.
        await FlutterPcmSound.feed(PcmArrayInt16.fromList(pcmChunk));

        // Check if the buffer is now empty *after* feeding
        if (_audioBuffer.isEmpty && mounted) {
           print(">>>> Audio buffer emptied during feed.");
           // Buffer is empty, likely end of received message
           // We don't stop playback engine here, it stops when its internal buffer runs dry.
           // Just update the UI state.
           setStateIfMounted(() {
              _isPlayingAudio = false; // Update UI icon
           });
        } else if (mounted && !_isPlayingAudio) {
           // If we just fed data and weren't marked as playing, update UI
           setStateIfMounted(() {
             _isPlayingAudio = true;
           });
        }

      } catch (e, s) {
        print("!!!! Error feeding PCM data: $e");
        print("!!!! Stack trace: $s");
        // Handle feed errors: clear buffer, stop playback, update state
        _audioBuffer.clear();
        await FlutterPcmSound.stop(); // Stop the engine on error
        setStateIfMounted(() {
           _isPcmSoundPlaying = false;
           _isPlayingAudio = false;
           _callStatus = "Audio Playback Error";
        });
      }
    } else {
      // Our buffer is empty. Don't feed anything.
      // print(">>>> PCM Feed callback: Buffer empty. Waiting for data.");
      // The playback engine will pause/stop if its internal buffer runs dry.
      // Update UI state if it wasn't already marked as not playing.
      if (mounted && _isPlayingAudio) {
        setStateIfMounted(() {
           _isPlayingAudio = false;
        });
      }
    }
  }


  // Starts the playback engine (if initialized and not already playing)
  void _startPcmSoundPlayback() {
    if (!_isAudioInitialized) {
      print("!!!! Cannot start PCM sound: Not initialized.");
      return;
    }
    if (_isPcmSoundPlaying) {
      print(">>>> PCM sound engine already playing (callback likely active).");
      // If engine is active, the feed callback will handle data when buffer has items.
      // Ensure UI state reflects potential playback start if buffer has data.
       if (_audioBuffer.isNotEmpty && !_isPlayingAudio && mounted) {
           setState(() => _isPlayingAudio = true);
       }
      return;
    }
    print(">>>> Starting FlutterPcmSound playback engine...");
    try {
      FlutterPcmSound.play(); // Start the engine; it will call _onFeedPcmSound
      setStateIfMounted(() {
        _isPcmSoundPlaying = true; // Mark engine as active
        // Update _isPlayingAudio based on buffer state immediately
        _isPlayingAudio = _audioBuffer.isNotEmpty;
      });
      print(">>>> FlutterPcmSound playback engine started.");

    } catch (e, s) {
      print("!!!! Error starting FlutterPcmSound playback engine: $e");
      print("!!!! Stack trace: $s");
      setStateIfMounted(() {
         _isPcmSoundPlaying = false;
         _isPlayingAudio = false;
         _callStatus = "Audio Playback Start Error";
      });
    }
  }

  // Stops the playback engine and clears buffers
  void _stopPcmSoundPlayback() {
    if (!_isPcmSoundPlaying && _audioBuffer.isEmpty) {
      print(">>>> PCM sound already stopped or idle.");
      return;
    }
    print(">>>> Stopping FlutterPcmSound playback...");

    try {
       // Stop the playback engine first
       FlutterPcmSound.stop();
       print(">>>> FlutterPcmSound engine stopped.");
    } catch (e, s) {
       print("!!!! Error stopping FlutterPcmSound engine: $e");
       print("!!!! Stack trace: $s");
       // Continue cleanup even on error
    }

    _audioBuffer.clear(); // Clear any remaining buffered data

    // Update state regardless of stop success/failure
    setStateIfMounted(() {
      _isPcmSoundPlaying = false; // Engine is no longer active
      _isPlayingAudio = false;    // No audio should be playing
    });
    print(">>>> FlutterPcmSound playback stopped, buffer cleared.");
  }

  // Handles incoming encrypted data, decrypts, converts, and buffers it
  void _handleEncryptedAudioData(Uint8List encryptedData) {
    // print(">>>> Handling encrypted audio data: ${encryptedData.length} bytes");
    if (_sharedKey == null) {
      print("!!!! Decrypt Error: Shared key is null. Discarding data.");
      return;
    }
    if (encryptedData.length <= gcmNonceLengthBytes) {
       print("!!!! Decrypt Error: Encrypted data too short. Discarding data.");
       return;
    }

    try {
      // Extract nonce (first 12 bytes)
      final nonce = encryptedData.sublist(0, gcmNonceLengthBytes);
      // The rest is ciphertext + authentication tag
      final ciphertextWithTag = encryptedData.sublist(gcmNonceLengthBytes);

      // Initialize AES-GCM for decryption
      final cipher = pc.GCMBlockCipher(pc.AESFastEngine());
      final params = pc.AEADParameters(pc.KeyParameter(_sharedKey!), gcmTagLengthBits, nonce, Uint8List(0));
      cipher.init(false, params); // false for decryption

      // Process the ciphertext to get original plaintext (PCM audio chunk)
      // This throws InvalidCipherTextException if authentication fails
      Uint8List decryptedBytes = cipher.process(ciphertextWithTag);

      // --- Convert Decrypted Bytes (PCM) to List<int> (Samples) ---
      if (decryptedBytes.isNotEmpty) {
        // Ensure length is even for int16 conversion
        if (decryptedBytes.lengthInBytes % 2 != 0) {
           print("!!!! Decrypted data has odd length (${decryptedBytes.lengthInBytes}), cannot convert to Int16. Discarding chunk.");
           return;
        }

        List<int> pcmSamples = [];
        ByteData byteData = ByteData.view(decryptedBytes.buffer, decryptedBytes.offsetInBytes, decryptedBytes.lengthInBytes);
        for (int i = 0; i < decryptedBytes.lengthInBytes; i += 2) {
          // Read two bytes as a signed 16-bit integer (Little Endian assumed)
          pcmSamples.add(byteData.getInt16(i, Endian.little));
        }

        // --- Add Samples to Buffer ---
        if (pcmSamples.isNotEmpty) {
           _audioBuffer.add(pcmSamples);
           // print(">>>> PCM Chunk (${pcmSamples.length} samples) added to buffer. Size: ${_audioBuffer.length}.");

           // --- Trigger Playback if Necessary ---
           // If the playback engine isn't running, start it now that we have data.
           if (!_isPcmSoundPlaying && _isAudioInitialized) {
              print(">>>> First audio chunk received/buffered, starting playback engine.");
              _startPcmSoundPlayback();
           }
           // Update UI state if playback should now be active
           else if (_isPcmSoundPlaying && !_isPlayingAudio && mounted) {
              // Engine was running but buffer might have been empty; update UI now
              setStateIfMounted(() => _isPlayingAudio = true);
           }

        } else {
           print(">>>> Decryption resulted in empty PCM samples after conversion, discarding.");
        }
      } else {
         print(">>>> Decryption resulted in empty byte data, discarding.");
      }

    } on pc.InvalidCipherTextException catch (e) {
      // This is critical - it means the data was tampered with or decryption failed badly.
      print("!!!! DECRYPTION FAILED (Authentication Tag Check Failed): $e. Discarding chunk.");
      // Consider implications: discard buffer? Notify user?
    } catch (e, s) {
      print("!!!! Decryption or Conversion/Buffer Add failed: $e");
      print("!!!! Stack trace: $s");
      // Handle other potential errors during processing
    }
  }

  // --- Speakerphone (Placeholder/Optional) ---
  Future<void> _setSpeakerphone(bool enable) async {
    if (kIsWeb) {
      print(">>>> Speakerphone control not available on Web.");
      return;
    }
    print(">>>> Setting speakerphone to: $enable (Placeholder)");
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
     } else {
       print(">>>> Requesting microphone permission...");
       status = await Permission.microphone.request();
       print(">>>> Permission request result: $status");
       if (status.isGranted) {
         print(">>>> Microphone permission granted after request.");
         return true;
       } else {
         print("!!!! Microphone permission denied or restricted after request.");
         // Optionally guide user to settings if permanently denied
         if (status.isPermanentlyDenied) {
            print("!!!! Permission permanently denied. Please enable in settings.");
            // Consider showing a dialog:
            // showDialog(context: context, builder: (_) => AlertDialog(...));
            // openAppSettings(); // From permission_handler package
         }
         return false;
       }
     }
   }


  // --- Cleanup Logic ---
  Future<void> _closeWebRTCSession({required bool notifyServer}) async {
    print(">>>> Entering _closeWebRTCSession (Notify Server: $notifyServer)...");

    bool wasInCall = _isInCall; // Track if we were in a call state

    // 1. Stop Media Streams and Playback
    if (_isTransmitting) {
       await _stopMicStream(); // Stop recording if active
       setStateIfMounted(() => _isTransmitting = false);
    }
     _stopPcmSoundPlayback(); // Stop playback and clear buffer

    // 2. Clear Queued Signals
    _queuedWebRTCSignals.clear();

    // 3. Notify Server (if requested and possible)
    if (notifyServer && _remoteUserId != null && _channel != null && _channel!.closeCode == null && wasInCall) {
      print(">>>> Sending hangUp message to $_remoteUserId due to local closure.");
      _sendMessage({'action': 'hangUp', 'toId': _remoteUserId!, 'fromId': _myId});
    }

    // 4. Close Data Channels
    try {
      if (_dataChannel != null) {
        print(">>>> Closing local data channel (ID: ${_dataChannel?.id})...");
        await _dataChannel!.close();
        print(">>>> Local data channel closed.");
      }
    } catch (e) {
      print("!!!! Error closing local data channel: $e");
    } finally {
       _dataChannel = null; // Ensure it's nullified
    }

    try {
      if (_remoteDataChannel != null) {
        print(">>>> Closing remote data channel (ID: ${_remoteDataChannel?.id})...");
        await _remoteDataChannel!.close();
        print(">>>> Remote data channel closed.");
      }
    } catch (e) {
      print("!!!! Error closing remote data channel: $e");
    } finally {
      _remoteDataChannel = null; // Ensure it's nullified
    }

    // 5. Close Peer Connection
    try {
      if (_peerConnection != null) {
        print(">>>> Closing PeerConnection...");
        await _peerConnection!.close();
        print(">>>> PeerConnection closed.");
      }
    } catch (e) {
      print("!!!! Error closing PeerConnection: $e");
    } finally {
      _peerConnection = null; // Ensure it's nullified
    }

    // 6. Dispose MediaStreams (though not used for audio track in this version)
    try { await _localStream?.dispose(); } catch (e) {/* Ignore */}
    _localStream = null;
    try { await _remoteStream?.dispose(); } catch (e) {/* Ignore */}
    _remoteStream = null;

    // 7. Reset QKD state if needed
    _qkdSimulator?.reset();
    _qkdSimulator = null;
    // Keep _sharedKey = null logic inside _resetCallState

    // 8. Reset overall call state
    _resetCallState();
    print(">>>> _closeWebRTCSession finished.");
  }

  // Resets all call-related state variables
  void _resetCallState() {
    print(">>>> Resetting call state...");

    // Preserve the final status message if it indicates a specific end reason
    bool preserveStatus = _callStatus.contains("Error") ||
                          _callStatus.contains("Failed") ||
                          _callStatus.contains("Permission") ||
                          _callStatus.contains("Lost") ||
                          _callStatus.contains("ended by") ||
                          _callStatus.contains("rejected") ||
                          _callStatus.contains("disconnect");

    String finalStatus = preserveStatus ? _callStatus : 'Ready'; // Default to Ready

    // Clear WebRTC/QKD related objects (should be done by _closeWebRTCSession ideally, but ensure here)
    _peerConnection = null;
    _dataChannel = null;
    _remoteDataChannel = null;
    _qkdSimulator = null;
    _sharedKey = null;
    _queuedWebRTCSignals.clear();

    // Reset state variables
    _isInCall = false;
    _remoteUserId = null;
    _qkdState = QkdState.idle;
    _isTransmitting = false;
    _remoteIsTransmitting = false;
    _isPcmSoundPlaying = false;
    _isPlayingAudio = false;
    _audioBuffer.clear();

     // Update UI state only if mounted
     if (mounted) {
       setState(() {
         _callStatus = finalStatus;
       });
     } else {
        _callStatus = finalStatus; // Update variable directly if not mounted
     }

    print(">>>> Call state reset complete. InCall: $_isInCall, Status: $_callStatus, QKD: $_qkdState");
  }

  // Helper to safely call setState only if the widget is still mounted
  void setStateIfMounted(VoidCallback fn) {
    if (mounted) {
      setState(fn);
    } else {
      print(">>>> setStateIfMounted: Widget not mounted, skipping setState.");
    }
  }


  // --- Digit Handling Functions (Unchanged) ---
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
        // Status Bar
        Container(
            padding: const EdgeInsets.symmetric(vertical: 12, horizontal: 20),
            color: _callStatus.contains("Error") || _callStatus.contains("Failed")
                ? Colors.red[100]
                : (_qkdState == QkdState.success && _isInCall)
                    ? Colors.lightGreen[100]
                    : (_qkdState == QkdState.exchanging ||
                            _callStatus.contains("Connecting") ||
                            _callStatus.contains("Calling"))
                        ? Colors.amber[100]
                        : Colors.blueGrey[100],
            width: double.infinity,
            child: Text(
                _callStatus.isEmpty ? (_isInCall ? 'Connecting...' : 'Ready') : _callStatus, // Ensure status shown
                textAlign: TextAlign.center,
                style: TextStyle(
                    fontWeight: FontWeight.bold,
                    fontSize: 16,
                    color: _callStatus.contains("Error") ||
                            _callStatus.contains("Failed")
                        ? Colors.red[900]
                        : Colors.black87))),
        // Main Content Area
        Expanded(
            child: AnimatedSwitcher( // Smooth transition between Dialer and InCall view
                duration: const Duration(milliseconds: 300),
                child: _isInCall ? _buildInCallView() : _buildDialerView(),
           ),
        ),
      ]),
      // Hangup Button (Only visible when in a call)
      floatingActionButtonLocation: FloatingActionButtonLocation.centerFloat,
      floatingActionButton: _isInCall
          ? FloatingActionButton(
              onPressed: _hangUp,
              backgroundColor: Colors.red,
              tooltip: 'Hang Up',
              child: const Icon(Icons.call_end, color: Colors.white),
            )
          : null, // No button when not in call
    );
  }


  // Builds the number pad view
  Widget _buildDialerView() {
    return Column(
        key: const ValueKey('dialerView'), // Key for AnimatedSwitcher
        children: <Widget>[
          // Display for entered number
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
          // Number Pad
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
                              _buildEmptyButton(), // Spacer
                              _buildNumberButton('0'),
                              _buildActionButton( // Delete button
                                  icon: Icons.backspace_outlined,
                                  onPressed: _deleteDigit,
                                  color: Colors.grey[300],
                                  iconColor: Colors.black54)
                            ])
                      ]))),
          // Call Button
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
                    // Enable button only when registered and 10 digits entered
                    onPressed: (_connectionStatus.startsWith('Registered') &&
                            _enteredNumber.length == 10)
                        ? _initiateSecureCall
                        : null, // Disabled otherwise
                  ))),
        ]);
  }

  // Builds the view shown during an active call (Push-to-Talk)
  Widget _buildInCallView() {
    // Determine if the connection is fully established and ready for PTT
     final bool isFullyConnected = _qkdState == QkdState.success &&
                                   _peerConnection?.connectionState == RTCPeerConnectionState.RTCPeerConnectionStateConnected &&
                                   (_dataChannel?.state == RTCDataChannelState.RTCDataChannelOpen ||
                                    _remoteDataChannel?.state == RTCDataChannelState.RTCDataChannelOpen);

     // Determine if the user *can* press the talk button
     final bool canTalk = isFullyConnected && !_isTransmitting && !_remoteIsTransmitting && !_isPlayingAudio;
     // Determine the text/state for the button
     String buttonText;
     Color buttonColor;
     if (_isTransmitting) {
        buttonText = 'Talking...';
        buttonColor = Colors.red[400]!;
     } else if (_remoteIsTransmitting) {
        buttonText = 'Receiving...';
        buttonColor = Colors.blueGrey; // Indicate busy receiving
     } else if (_isPlayingAudio) {
        buttonText = 'Playing...';
        buttonColor = Colors.blueGrey; // Indicate busy playing
     }
     else if (isFullyConnected) {
        buttonText = 'Hold to Talk';
        buttonColor = Colors.green;
     } else {
        buttonText = 'Connecting...'; // Or show specific connection status
        buttonColor = Colors.orange;
     }


    return Center(
      key: const ValueKey('inCallView'), // Key for AnimatedSwitcher
      child: Padding(
        padding: const EdgeInsets.all(20.0),
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          crossAxisAlignment: CrossAxisAlignment.center,
          children: [
             // Indicate Secure Connection visually
             if (isFullyConnected)
               const Icon(Icons.lock, color: Colors.green, size: 30),
             if (_qkdState == QkdState.exchanging)
                const CircularProgressIndicator(), // Show progress during QKD

             const SizedBox(height: 8),
             // Show remote user ID
             Text(
               _remoteUserId != null ? 'Connected to: $_remoteUserId' : 'Establishing Connection...',
               style: Theme.of(context).textTheme.titleMedium?.copyWith(color: Colors.black54),
               textAlign: TextAlign.center,
             ),
             const SizedBox(height: 8),
             // Dynamic status text based on PTT state
              Text(
                 _isTransmitting ? 'Transmitting Your Voice...' : (_remoteIsTransmitting ? 'Receiving Voice...' : (_isPlayingAudio ? 'Playing Received Voice...' : (isFullyConnected ? 'Ready' : ''))),
                 style: Theme.of(context).textTheme.titleMedium?.copyWith(
                   color: _isTransmitting ? Colors.red : (_remoteIsTransmitting || _isPlayingAudio ? Colors.blue : Colors.black54)
                 ),
                 textAlign: TextAlign.center,
             ),

            const Spacer(), // Pushes button towards the bottom

            // --- Hold to Talk Button ---
            if (isFullyConnected || !isFullyConnected && _isInCall) // Show button area even while connecting
              GestureDetector(
                onTapDown: (_) { // Finger Pressed Down
                  if (canTalk && _dataChannel != null) {
                    print(">>>> Talk button PRESSED");
                    // 1. Update state
                    setState(() => _isTransmitting = true);
                    // 2. Signal start to remote peer
                     if (_remoteUserId != null) {
                        _sendMessage({
                          'action': 'startTalking',
                          'toId': _remoteUserId!,
                          'fromId': _myId,
                        });
                     }
                    // 3. Start microphone capture and streaming
                    _startMicStream(_dataChannel!);
                  } else if (!isFullyConnected) {
                     print(">>>> Talk button pressed, but not fully connected yet.");
                     ScaffoldMessenger.of(context).showSnackBar(
                        const SnackBar(content: Text('Connection not ready yet.'), duration: Duration(seconds: 1)),
                      );
                  } else if (_remoteIsTransmitting) {
                     print(">>>> Talk button pressed, but remote is transmitting.");
                     ScaffoldMessenger.of(context).showSnackBar(
                        const SnackBar(content: Text('Other user is talking.'), duration: Duration(seconds: 1)),
                      );
                  } else if (_isPlayingAudio) {
                     print(">>>> Talk button pressed, but audio is playing.");
                     ScaffoldMessenger.of(context).showSnackBar(
                        const SnackBar(content: Text('Wait for playback to finish.'), duration: Duration(seconds: 1)),
                     );
                  } else {
                     print(">>>> Talk button pressed, but cannot talk now (State: ${_dataChannel?.state}, Transmitting: $_isTransmitting, Remote: $_remoteIsTransmitting)");
                  }
                },
                onTapUp: (_) { // Finger Released
                  if (_isTransmitting) {
                    print(">>>> Talk button RELEASED");
                    _stopMicAndSignal(); // Stop mic and signal peer
                  }
                },
                onTapCancel: () { // Finger Slid Off / Cancelled
                 if (_isTransmitting) {
                    print(">>>> Talk button CANCELLED");
                    _stopMicAndSignal(); // Treat cancel like release
                 }
                },
                child: Container(
                  padding: const EdgeInsets.symmetric(horizontal: 40, vertical: 20),
                  decoration: BoxDecoration(
                    color: buttonColor, // Dynamic color based on state
                    borderRadius: BorderRadius.circular(30),
                    boxShadow: [ // Subtle shadow effect
                      BoxShadow(
                        color: Colors.black.withOpacity(0.2),
                        spreadRadius: 1,
                        blurRadius: 4,
                        offset: const Offset(0, 2),
                      ),
                    ]
                  ),
                  child: Text(
                    buttonText, // Dynamic text
                    style: const TextStyle(color: Colors.white, fontSize: 18, fontWeight: FontWeight.bold),
                  ),
                ),
              )
            else if (!isFullyConnected && _isInCall) // Show loading indicator if connecting
              const CircularProgressIndicator()
             else // Fallback (shouldn't happen if logic is correct)
              const SizedBox(),


            const SizedBox(height: 20), // Space below button

            // --- Audio Status Indicators ---
             Row(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                // Microphone Icon (Red when transmitting)
                Icon(
                  _isTransmitting ? Icons.mic : Icons.mic_off,
                  color: _isTransmitting ? Colors.red : Colors.grey,
                  size: 24,
                ),
                const SizedBox(width: 40), // Increased spacing
                // Speaker/Audio Output Icon (Blue when playing received audio)
                Icon(
                  _isPlayingAudio ? Icons.graphic_eq : Icons.volume_up, // Use graphic_eq when playing
                  color: _isPlayingAudio ? Colors.blue : Colors.grey,
                  size: 24,
                ),
              ],
            ),


            const SizedBox(height: 80), // Space to push content above the Hang Up FAB
          ],
        ),
      ),
    );
  }

  // --- Helper Widgets for Dialer View (Unchanged) ---
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
    return const Expanded(child: SizedBox()); // Used for layout spacing
  }

} // End of _DialerScreenState class