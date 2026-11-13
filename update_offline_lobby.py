import sys

file_path = r'C:\JOEPAUL\Comms\lib\screens\chat\offline_lobby_screen.dart'
with open(file_path, 'r', encoding='utf-8') as f:
    content = f.read()

# Change _startRadar to just start discovery
old_radar = """  Future<void> _startRadar() async {
    final user = FirebaseAuth.instance.currentUser;
    final name = user?.displayName ?? "Unknown User";
    
    await _offlineService.startAdvertising(name);
    await _offlineService.startDiscovery(name);
  }"""

new_radar = """  Future<void> _startRadar() async {
    final user = FirebaseAuth.instance.currentUser;
    final name = user?.displayName ?? "Unknown User";
    
    // Advertising is handled passively in ChatListScreen. Just start discovery here.
    await _offlineService.startDiscovery(name);
  }"""

content = content.replace(old_radar, new_radar)

# Change isActive to only track isDiscovering
old_active = """    final isActive = _offlineService.isAdvertising || _offlineService.isDiscovering;"""
new_active = """    final isActive = _offlineService.isDiscovering;"""
content = content.replace(old_active, new_active)

# Change disconnect to only stop discovery
old_ontap = """          GestureDetector(
            onTap: isActive ? _offlineService.disconnect : _startRadar,"""
new_ontap = """          GestureDetector(
            onTap: isActive ? () {
              // Only stop discovery, keep passive advertising active
              import_nearby_package_if_needed_maybe_no_wait_service_has_method_for_this;
            } : _startRadar,"""

# Let's add stopDiscovery to offline_chat_service.dart or just call Nearby().stopDiscovery() directly.
# Wait, let's just make it simpler by adding stopDiscovery to OfflineChatService if it's not there.
# Actually, I can just use Nearby().stopDiscovery() if I import nearby_connections.
# Or better, I can just call _offlineService.isDiscovering = false; Nearby().stopDiscovery(); ... Wait, the service has a disconnect() that stops both. Let's just create stopDiscovery in the service, or just use the service's `disconnect` but that stops advertising too.
# Let's change onTap to stop discovery
new_ontap_real = """          GestureDetector(
            onTap: isActive ? () {
              _offlineService.isDiscovering = false;
              // Because Nearby() requires import, let's just let it run or rely on the service.
            } : _startRadar,"""
# Since this is a bit messy, let's just do it directly.
