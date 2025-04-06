// lib/bb84_simulator.dart
import 'dart:math';
import 'dart:typed_data';
import 'package:pointycastle/digests/sha256.dart'; // For hashing (Privacy Amplification)

class BB84Simulator {
  final int keyLength; // Desired number of initial qubits/bits
  final bool isAlice; // Role: true if initiating, false if receiving
  final Function(Map<String, dynamic>) sendSignal; // Callback to send data via WebSocket
  final Function(Uint8List?) onKeyDerived; // Callback when key is ready (or null on failure)

  List<int>? _aliceBits;
  List<int>? _aliceBases;
  List<int>? _bobBases;
  List<int>? _bobMeasuredBits; // What Bob measures (simulated)
  List<int>? _receivedSiftedBits;

  List<int>? _peerBases; // Bases received from the peer

  List<int>? _siftedKeyIndices;
  Uint8List? _derivedKey;

  bool _basesSent = false;
  bool _basesReceived = false;

  // Minimum length for the final key after sifting/hashing
  static const int minFinalKeyLengthBytes = 16; // e.g., 128 bits

  BB84Simulator({
    required this.keyLength,
    required this.isAlice,
    required this.sendSignal,
    required this.onKeyDerived,
  }) {
    if (keyLength <= 0 || keyLength % 8 != 0) {
      throw ArgumentError("keyLength must be a positive multiple of 8.");
    }
  }

  void startExchange() {
    print("BB84: Starting exchange (Role: ${isAlice ? 'Alice' : 'Bob'})");
    reset(); // Ensure clean state

    if (isAlice) {
      _aliceBits = _generateRandomSequence(keyLength);
      _aliceBases = _generateRandomSequence(keyLength);
      print("BB84 Alice: Generated ${_aliceBits!.length} bits and bases.");
      // Alice waits for Bob to be ready or sends her bases directly
      // For simplicity, let's have Alice send bases first in this simulation
       _sendBases();
    } else {
      _bobBases = _generateRandomSequence(keyLength);
      print("BB84 Bob: Generated ${_bobBases!.length} bases.");
      // Bob sends his bases (or a ready signal)
       _sendBases(); // Both send bases simultaneously in this simple model
    }
  }


  void processSignal(Map<String, dynamic> signal) {
    final type = signal['type'];
    // data can be List<dynamic> for bases or siftedBits
    final data = signal['data'];

    print("BB84: Processing signal type '$type'");

    switch (type) {
      case 'bases':
        if (data is List) {
          try {
              _peerBases = data.map((e) => e as int).toList();
              _basesReceived = true;
              print("BB84: Received ${_peerBases?.length ?? 0} bases from peer.");
              _checkAndCompareBases();
          } catch (e) {
              print("BB84 Error: Received bases data is not List<int>. $e");
              _abortExchange("Invalid bases format received");
          }
        } else {
          print("BB84 Error: Received bases data is not a List.");
            _abortExchange("Invalid bases format received");
        }
        break;

      // --- NEW CASE ---
      case 'siftedBits':
        if (!isAlice) { // Only Bob processes this
          if (data is List) {
              try {
                _receivedSiftedBits = data.map((e) => e as int).toList();
                print("BB84 Bob: Received ${_receivedSiftedBits!.length} sifted bits from Alice.");
                // Now that Bob has the bits, proceed to hashing
                _hashReceivedSiftedKey();
              } catch (e) {
                print("BB84 Error: Received siftedBits data is not List<int>. $e");
                  _abortExchange("Invalid siftedBits format received");
              }
          } else {
              print("BB84 Error: Received siftedBits data is not a List.");
              _abortExchange("Invalid siftedBits format received");
          }
        } else {
          print("BB84 Alice: Ignored own siftedBits message."); // Should not happen
        }
        break;
      // --- END NEW CASE ---

      // Add other signal types if needed (e.g., for error correction steps)
      default:
        print("BB84: Unknown signal type '$type'");
    }
  }

  void _sendBases() {
     if (_basesSent) return;

     List<int>? basesToSend = isAlice ? _aliceBases : _bobBases;
     if (basesToSend != null) {
        print("BB84: Sending bases...");
        sendSignal({
           'type': 'bases',
           'data': basesToSend, // Send the list of bases
        });
        _basesSent = true;
        _checkAndCompareBases(); // Check if ready to compare
     } else {
        print("BB84 Error: Tried to send null bases.");
     }
  }

   void _checkAndCompareBases() {
      // Proceed only if both sent and received bases
      if (_basesSent && _basesReceived && _peerBases != null) {
         print("BB84: Both parties have exchanged bases. Comparing...");
         _compareBases();
      } else {
          print("BB84: Waiting for peer's bases...");
      }
   }


  void _compareBases() {
      if (_peerBases == null) {
        _abortExchange("Cannot compare bases, peer bases missing.");
        return;
      }

      List<int>? myBases = isAlice ? _aliceBases : _bobBases;
      if (myBases == null || myBases.length != _peerBases!.length) {
          _abortExchange("Basis length mismatch or my bases missing.");
          return;
      }

      _siftedKeyIndices = [];
      for (int i = 0; i < myBases.length; i++) {
        if (myBases[i] == _peerBases![i]) {
            _siftedKeyIndices!.add(i); // Store index where bases matched
        }
      }

      print("BB84: Bases compared. Found ${_siftedKeyIndices!.length} matching bases (sifted key length).");

      // --- MODIFIED LOGIC ---
      if (_siftedKeyIndices!.isEmpty) {
        _abortExchange("No matching bases found after sifting.");
        return;
      }

      // Alice proceeds to extract, send, and hash her bits
      if (isAlice) {
          print("BB84 Alice: Preparing to send sifted bits and hash key.");
        _performSiftingAndHashing(); // Alice calculates, sends, and hashes
      } else {
        // Bob WAITS for Alice to send the sifted bits.
        // The hashing will be triggered by the 'siftedBits' message in processSignal.
        print("BB84 Bob: Waiting for sifted bits from Alice...");
      }
      // --- END MODIFIED LOGIC ---

      // --- Simplification: Skip Error Estimation & Correction ---
      // ... (rest of comments remain) ...
  }

 void _performSiftingAndHashing() {
     // This function is now primarily called by ALICE after comparing bases.
     // Bob will call a separate hashing function once bits are received.

     if (!isAlice) {
         // This path should ideally not be hit anymore due to changes in _compareBases
         print("BB84 Warning: _performSiftingAndHashing called unexpectedly by Bob.");
         // If it does get called, ensure we don't use the old faulty logic
         _abortExchange("Internal logic error: Bob tried to perform sifting directly.");
         return;
     }

     // --- Alice's Logic ---
     if (_siftedKeyIndices == null || _siftedKeyIndices!.isEmpty) {
         _abortExchange("Alice cannot sift: No matching bases found.");
         return;
     }
     if (_aliceBits == null) {
          _abortExchange("Alice's bits missing for sifting."); return;
     }

     // 1. Extract Sifted Bits
     List<int> siftedKeyBits = _siftedKeyIndices!.map((index) => _aliceBits![index]).toList();
     print("BB84 Alice: Extracted ${siftedKeyBits.length} sifted bits.");

     // 2. Send Sifted Bits to Bob
     print("BB84 Alice: Sending ${siftedKeyBits.length} sifted bits to Bob...");
     sendSignal({
         'type': 'siftedBits',
         'data': siftedKeyBits,
     });

     // 3. Privacy Amplification (Hashing) - Alice hashes her own copy
     if (siftedKeyBits.length < minFinalKeyLengthBytes * 8) {
         _abortExchange("Alice: Sifted key too short (${siftedKeyBits.length} bits) before hashing.");
         return;
     }

     _hashSiftedKey(siftedKeyBits, "Alice"); // Use a common hashing function
 }

 // --- NEW Function for Bob (called from processSignal) ---
 void _hashReceivedSiftedKey() {
     if (isAlice) {
         print("BB84 Warning: _hashReceivedSiftedKey called by Alice.");
         return; // Should not happen
     }
     if (_receivedSiftedBits == null) {
         _abortExchange("Bob cannot hash: Sifted bits not received.");
         return;
     }
      print("BB84 Bob: Proceeding to hash received sifted bits.");

     if (_receivedSiftedBits!.length < minFinalKeyLengthBytes * 8) {
         _abortExchange("Bob: Received sifted key too short (${_receivedSiftedBits!.length} bits).");
         return;
     }

     _hashSiftedKey(_receivedSiftedBits!, "Bob"); // Use the common hashing function
 }

 // --- NEW Common Hashing Function ---
 void _hashSiftedKey(List<int> keyBits, String role) {
     // Pack bits into bytes
     List<int> packedBytes = [];
     for (int i = 0; i < keyBits.length; i += 8) {
         int byte = 0;
         for (int j = 0; j < 8; j++) {
             if (i + j < keyBits.length && keyBits[i + j] == 1) {
                 byte |= (1 << (7 - j));
             }
         }
         packedBytes.add(byte);
     }
     final siftedBytes = Uint8List.fromList(packedBytes);

     // Use SHA-256 for hashing
     final digest = SHA256Digest();
     _derivedKey = digest.process(siftedBytes); // Result is 32 bytes (256 bits)

     print("BB84 $role: Derived final key (SHA-256 hash): ${_derivedKey?.length} bytes.");

     if (_derivedKey != null && _derivedKey!.length >= minFinalKeyLengthBytes) {
         onKeyDerived(_derivedKey); // Success! Pass key back.
     } else {
         _abortExchange("$role: Failed to generate final key of sufficient length after hashing.");
     }
 }
   void _abortExchange(String reason) {
       print("BB84 Error: Aborting exchange - $reason");
       reset();
       onKeyDerived(null); // Signal failure
   }

  void reset() {
    _aliceBits = null;
    _aliceBases = null;
    _bobBases = null;
    _bobMeasuredBits = null;
    _peerBases = null;
    _siftedKeyIndices = null;
    _receivedSiftedBits = null;
    _derivedKey = null;
    _basesSent = false;
    _basesReceived = false;
  }

  // Helper to generate random 0s and 1s
  List<int> _generateRandomSequence(int length) {
    final random = Random.secure();
    return List<int>.generate(length, (_) => random.nextInt(2));
  }
}