import 'package:flutter/material.dart';
import 'package:google_fonts/google_fonts.dart';
import 'package:firebase_auth/firebase_auth.dart';
import '../../theme/app_colors.dart';
import '../../services/offline_chat_service.dart';
import 'offline_chat_screen.dart';

class OfflineLobbyScreen extends StatefulWidget {
  const OfflineLobbyScreen({super.key});

  @override
  State<OfflineLobbyScreen> createState() => _OfflineLobbyScreenState();
}

class _OfflineLobbyScreenState extends State<OfflineLobbyScreen> {
  final OfflineChatService _offlineService = OfflineChatService();
  bool _hasPermissions = false;

  @override
  void initState() {
    super.initState();
    _initOffline();
    _offlineService.addListener(_onServiceUpdate);
  }

  @override
  void dispose() {
    _offlineService.removeListener(_onServiceUpdate);
    // Don't disconnect if we just navigated to the chat screen
    if (_offlineService.connectedEndpointId == null) {
      _offlineService.disconnect();
    }
    super.dispose();
  }

  void _onServiceUpdate() {
    if (mounted) setState(() {});
    
    // Automatically navigate to chat if connected
    if (_offlineService.connectedEndpointId != null) {
      Navigator.pushReplacement(
        context,
        MaterialPageRoute(builder: (_) => const OfflineChatScreen()),
      );
    }
  }

  Future<void> _initOffline() async {
    _hasPermissions = await _offlineService.requestPermissions();
    if (mounted) setState(() {});
  }

  Future<void> _startRadar() async {
    final user = FirebaseAuth.instance.currentUser;
    final name = user?.displayName ?? "Unknown User";
    
    await _offlineService.startAdvertising(name);
    await _offlineService.startDiscovery(name);
  }

  @override
  Widget build(BuildContext context) {
    final isActive = _offlineService.isAdvertising || _offlineService.isDiscovering;
    
    return Scaffold(
      backgroundColor: AppColors.bg,
      appBar: AppBar(
        backgroundColor: AppColors.bg,
        elevation: 0,
        title: Text(
          'Offline Radar',
          style: GoogleFonts.outfit(
            fontWeight: FontWeight.w600,
            color: AppColors.text,
          ),
        ),
        iconTheme: const IconThemeData(color: AppColors.text),
      ),
      body: Column(
        children: [
          const SizedBox(height: 40),
          // Radar Animation Placeholder / Button
          GestureDetector(
            onTap: isActive ? _offlineService.disconnect : _startRadar,
            child: Center(
              child: Container(
                width: 200,
                height: 200,
                decoration: BoxDecoration(
                  shape: BoxShape.circle,
                  color: isActive 
                      ? AppColors.primary.withValues(alpha: 0.1) 
                      : AppColors.bgAlt,
                  border: Border.all(
                    color: isActive ? AppColors.primary : AppColors.textMuted,
                    width: isActive ? 3 : 1,
                  ),
                  boxShadow: isActive ? [
                    BoxShadow(
                      color: AppColors.primary.withValues(alpha: 0.2),
                      blurRadius: 40,
                      spreadRadius: 10,
                    )
                  ] : null,
                ),
                child: Center(
                  child: Column(
                    mainAxisAlignment: MainAxisAlignment.center,
                    children: [
                      Icon(
                        isActive ? Icons.radar_rounded : Icons.bluetooth_searching_rounded,
                        size: 48,
                        color: isActive ? AppColors.primary : AppColors.textMuted,
                      ),
                      const SizedBox(height: 12),
                      Text(
                        isActive ? 'Scanning...' : 'Tap to Scan',
                        style: GoogleFonts.inter(
                          fontWeight: FontWeight.w600,
                          color: isActive ? AppColors.primary : AppColors.textMuted,
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            ),
          ),
          const SizedBox(height: 40),
          
          Text(
            'Discovered Devices',
            style: GoogleFonts.outfit(
              fontSize: 18,
              fontWeight: FontWeight.w600,
              color: AppColors.text,
            ),
          ),
          const SizedBox(height: 16),
          
          Expanded(
            child: _offlineService.discoveredPeers.isEmpty
                ? Center(
                    child: Text(
                      isActive ? 'Looking for nearby friends...' : 'Radar is off',
                      style: GoogleFonts.inter(color: AppColors.textMuted),
                    ),
                  )
                : ListView.builder(
                    padding: const EdgeInsets.symmetric(horizontal: 16),
                    itemCount: _offlineService.discoveredPeers.length,
                    itemBuilder: (context, index) {
                      final peer = _offlineService.discoveredPeers.values.elementAt(index);
                      final user = FirebaseAuth.instance.currentUser;
                      
                      return Card(
                        color: AppColors.bgAlt,
                        margin: const EdgeInsets.only(bottom: 8),
                        child: ListTile(
                          leading: const CircleAvatar(
                            backgroundColor: AppColors.primary,
                            child: Icon(Icons.person, color: Colors.white),
                          ),
                          title: Text(
                            peer.name,
                            style: GoogleFonts.inter(
                              color: AppColors.text,
                              fontWeight: FontWeight.w600,
                            ),
                          ),
                          subtitle: Text(
                            'Tap to connect',
                            style: GoogleFonts.inter(
                              color: AppColors.textMuted,
                              fontSize: 12,
                            ),
                          ),
                          onTap: () {
                            _offlineService.requestConnection(
                              user?.displayName ?? "Unknown", 
                              peer.id,
                            );
                            
                            ScaffoldMessenger.of(context).showSnackBar(
                              SnackBar(
                                content: Text('Requesting connection to ${peer.name}...'),
                                backgroundColor: AppColors.bgAlt,
                              ),
                            );
                          },
                        ),
                      );
                    },
                  ),
          ),
        ],
      ),
    );
  }
}
