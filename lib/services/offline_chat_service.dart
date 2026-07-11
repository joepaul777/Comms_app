import 'dart:convert';
import 'dart:typed_data';
import 'package:flutter/foundation.dart';
import 'package:nearby_connections/nearby_connections.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:uuid/uuid.dart';
import 'package:firebase_auth/firebase_auth.dart';
import '../models/message_model.dart';

// Represents a discovered nearby device
class OfflinePeer {
  final String id; // The nearby connections endpoint ID
  final String name; // The advertised name
  bool isConnected;
  OfflinePeer(this.id, this.name, {this.isConnected = false});
}

class OfflineChatService extends ChangeNotifier {
  static final OfflineChatService _instance = OfflineChatService._internal();
  factory OfflineChatService() => _instance;
  OfflineChatService._internal();

  final Strategy strategy = Strategy.P2P_CLUSTER;
  final String serviceId = "com.joepaul.comms.offline";
  
  bool isAdvertising = false;
  bool isDiscovering = false;
  
  // List of discovered peers
  Map<String, OfflinePeer> discoveredPeers = {};
  
  // Connected endpoint
  String? connectedEndpointId;
  String? connectedEndpointName;

  // In-memory messages for the current session (disappears on disconnect)
  List<MessageModel> messages = [];

  // Initialize permissions
  Future<bool> requestPermissions() async {
    // Request required permissions for Nearby Connections via permission_handler
    Map<Permission, PermissionStatus> statuses = await [
      Permission.bluetooth,
      Permission.bluetoothAdvertise,
      Permission.bluetoothConnect,
      Permission.bluetoothScan,
      Permission.location,
      Permission.nearbyWifiDevices,
    ].request();
    
    // We consider it a success if we get location and basic bluetooth
    return statuses[Permission.location]?.isGranted == true;
  }

  // Advertising
  Future<void> startAdvertising(String userName) async {
    try {
      isAdvertising = await Nearby().startAdvertising(
        userName,
        strategy,
        onConnectionInitiated: _onConnectionInitiated,
        onConnectionResult: _onConnectionResult,
        onDisconnected: _onDisconnected,
        serviceId: serviceId,
      );
      notifyListeners();
    } catch (e) {
      print("Error advertising: $e");
    }
  }

  // Discovery
  Future<void> startDiscovery(String userName) async {
    try {
      isDiscovering = await Nearby().startDiscovery(
        userName,
        strategy,
        onEndpointFound: (id, name, serviceId) {
          discoveredPeers[id] = OfflinePeer(id, name);
          notifyListeners();
        },
        onEndpointLost: (id) {
          discoveredPeers.remove(id);
          notifyListeners();
        },
        serviceId: serviceId,
      );
      notifyListeners();
    } catch (e) {
      print("Error discovering: $e");
    }
  }

  // Request Connection
  Future<void> requestConnection(String userName, String endpointId) async {
    try {
      await Nearby().requestConnection(
        userName,
        endpointId,
        onConnectionInitiated: _onConnectionInitiated,
        onConnectionResult: _onConnectionResult,
        onDisconnected: _onDisconnected,
      );
    } catch (e) {
      print("Error requesting connection: $e");
    }
  }

  // Connection Callbacks
  void _onConnectionInitiated(String endpointId, ConnectionInfo info) async {
    // Auto-accept connection for simplicity in Offline Mode
    await Nearby().acceptConnection(
      endpointId,
      onPayLoadRecieved: _onPayloadReceived,
      onPayloadTransferUpdate: (endpointId, payloadTransferUpdate) {},
    );
  }

  void _onConnectionResult(String endpointId, Status status) {
    if (status == Status.CONNECTED) {
      connectedEndpointId = endpointId;
      if (discoveredPeers.containsKey(endpointId)) {
        discoveredPeers[endpointId]!.isConnected = true;
        connectedEndpointName = discoveredPeers[endpointId]!.name;
      } else {
        connectedEndpointName = "Peer $endpointId";
      }
      
      // Stop discovery/advertising once connected
      Nearby().stopDiscovery();
      Nearby().stopAdvertising();
      isDiscovering = false;
      isAdvertising = false;
      
      notifyListeners();
    }
  }

  void _onDisconnected(String endpointId) {
    connectedEndpointId = null;
    connectedEndpointName = null;
    if (discoveredPeers.containsKey(endpointId)) {
      discoveredPeers[endpointId]!.isConnected = false;
    }
    // Clear messages when disconnected per user request
    messages.clear();
    notifyListeners();
  }

  // Messaging
  Future<void> sendMessage(String text, {String? senderId, String? senderName}) async {
    if (connectedEndpointId == null) return;
    
    final uid = senderId ?? FirebaseAuth.instance.currentUser?.uid ?? 'unknown';
    final name = senderName ?? 'Me';

    final message = MessageModel(
      id: const Uuid().v4(),
      senderId: uid,
      senderName: name,
      text: text,
      timestamp: DateTime.now(),
      type: MessageType.text,
    );

    // Add to local state
    messages.insert(0, message); // Insert at 0 because ListView is reverse
    notifyListeners();

    // Serialize and send
    final jsonStr = jsonEncode(message.toMap());
    final bytes = Uint8List.fromList(utf8.encode(jsonStr));
    await Nearby().sendBytesPayload(connectedEndpointId!, bytes);
  }

  void _onPayloadReceived(String endpointId, Payload payload) {
    if (payload.type == PayloadType.BYTES) {
      try {
        final jsonStr = utf8.decode(payload.bytes!);
        final map = jsonDecode(jsonStr);
        final message = MessageModel.fromMap(map);
        messages.insert(0, message); // Insert at 0 because ListView is reverse
        notifyListeners();
      } catch (e) {
        print("Failed to decode offline message: $e");
      }
    }
  }

  void disconnect() {
    if (connectedEndpointId != null) {
      Nearby().disconnectFromEndpoint(connectedEndpointId!);
    }
    Nearby().stopAllEndpoints();
    Nearby().stopDiscovery();
    Nearby().stopAdvertising();
    isDiscovering = false;
    isAdvertising = false;
    connectedEndpointId = null;
    connectedEndpointName = null;
    messages.clear();
    discoveredPeers.clear();
    notifyListeners();
  }
}
