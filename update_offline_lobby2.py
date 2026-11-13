import sys

file_path = r'C:\JOEPAUL\Comms\lib\services\offline_chat_service.dart'
with open(file_path, 'r', encoding='utf-8') as f:
    content = f.read()

# Add stopDiscovery to offline_chat_service.dart
if "void stopDiscoveryOnly() {" not in content:
    old_disc = """  void disconnect() {"""
    new_disc = """  void stopDiscoveryOnly() {
    Nearby().stopDiscovery();
    isDiscovering = false;
    discoveredPeers.clear();
    notifyListeners();
  }

  void disconnect() {"""
    content = content.replace(old_disc, new_disc)
    
    with open(file_path, 'w', encoding='utf-8') as f:
        f.write(content)

lobby_path = r'C:\JOEPAUL\Comms\lib\screens\chat\offline_lobby_screen.dart'
with open(lobby_path, 'r', encoding='utf-8') as f:
    lobby = f.read()

lobby = lobby.replace("""  Future<void> _startRadar() async {
    final user = FirebaseAuth.instance.currentUser;
    final name = user?.displayName ?? "Unknown User";
    
    await _offlineService.startAdvertising(name);
    await _offlineService.startDiscovery(name);
  }""", """  Future<void> _startRadar() async {
    final user = FirebaseAuth.instance.currentUser;
    final name = user?.displayName ?? "Unknown User";
    
    await _offlineService.startDiscovery(name);
  }""")

lobby = lobby.replace("""final isActive = _offlineService.isAdvertising || _offlineService.isDiscovering;""", """final isActive = _offlineService.isDiscovering;""")

lobby = lobby.replace("""onTap: isActive ? _offlineService.disconnect : _startRadar,""", """onTap: isActive ? _offlineService.stopDiscoveryOnly : _startRadar,""")

lobby = lobby.replace("""if (_offlineService.connectedEndpointId == null) {
      _offlineService.disconnect();
    }""", """if (_offlineService.connectedEndpointId == null) {
      _offlineService.stopDiscoveryOnly();
    }""")

with open(lobby_path, 'w', encoding='utf-8') as f:
    f.write(lobby)

print("Updated offline lobby successfully!")
