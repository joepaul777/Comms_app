import 'dart:convert';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:image_cropper/image_cropper.dart';
import 'package:image_picker/image_picker.dart';
import 'package:package_info_plus/package_info_plus.dart';
import 'package:url_launcher/url_launcher.dart';
import '../../models/user_model.dart';
import '../../services/app_lock.dart';
import '../../services/auth_service.dart';
import '../../services/notification_service.dart';
import '../../services/update_service.dart';
import '../../services/user_service.dart';
import '../../services/walkie_service.dart';
import '../../theme/app_colors.dart';
import '../../theme/app_theme.dart';
import '../../widgets/avatar.dart';
import '../../widgets/ui.dart';
import '../chat/offline_lobby_screen.dart';
import '../update/update_sheet.dart';
import '../../platform/platform.dart';

class ProfileScreen extends StatefulWidget {
  final UserModel me;
  const ProfileScreen({super.key, required this.me});

  @override
  State<ProfileScreen> createState() => _ProfileScreenState();
}

class _ProfileScreenState extends State<ProfileScreen> {
  late final Stream<UserModel?> _meStream = UserService.instance.userStream(widget.me.uid);
  PackageInfo? _info;
  bool _checking = false;
  bool _updateWaiting = false;

  @override
  void initState() {
    super.initState();
    UpdateService.current().then((i) {
      if (mounted) setState(() => _info = i);
    });
    UpdateService.newerRelease().then((r) {
      if (mounted && r != null) setState(() => _updateWaiting = true);
    });
    if (!kIsWeb) {
      Walkie.enabled().then((on) {
        if (mounted) setState(() => _walkie = on);
      });
    }
    if (kIsWeb) {
      NotificationService.instance.permitted().then((on) {
        if (mounted) setState(() => _notifications = on);
      });
    }
  }

  bool _notifications = false;
  bool _walkie = false;

  Future<void> _toggleWalkie(bool on) async {
    setState(() => _walkie = on);
    try {
      await Walkie.setEnabled(widget.me.uid, on);
      if (mounted && on) showSnack(context, 'People can now talk to you by holding your chat. Silent mode keeps it quiet.');
    } catch (_) {
      if (mounted) {
        setState(() => _walkie = !on);
        showSnack(context, 'Could not change walkie-talkie. Check your connection.', error: true);
      }
    }
  }

  Future<void> _askForNotifications() async {
    final service = NotificationService.instance;
    if (service.isApplePhone && !service.isInstalled) {
      showSnack(context, 'On iPhone, first add Comms to your Home Screen: tap Share, then "Add to Home Screen".');
      return;
    }
    final on = await service.askPermission();
    if (!mounted) return;
    setState(() => _notifications = on);
    if (!on) showSnack(context, 'Notifications are blocked. Allow them from the icon next to the address bar.', error: true);
  }

  Future<void> _changePhoto() async {
    // The browser has no cropper; the photo is just made small (the app shows it round).
    final picked = await ImagePicker().pickImage(
      source: ImageSource.gallery,
      maxWidth: kIsWeb ? 384 : null,
      maxHeight: kIsWeb ? 384 : null,
      imageQuality: kIsWeb ? 70 : null,
    );
    if (picked == null) return;
    if (kIsWeb) {
      final bytes = await picked.readAsBytes();
      await UserService.instance.updateProfile(widget.me.uid, photoUrl: 'data:${picked.mimeType ?? 'image/jpeg'};base64,${base64Encode(bytes)}');
      if (mounted) showSnack(context, 'Photo updated');
      return;
    }
    final cropped = await ImageCropper().cropImage(
      sourcePath: picked.path,
      aspectRatio: const CropAspectRatio(ratioX: 1, ratioY: 1),
      compressQuality: 70,
      maxWidth: 384,
      maxHeight: 384,
      uiSettings: [
        AndroidUiSettings(
          toolbarTitle: 'Crop photo',
          toolbarColor: AppColors.bg,
          toolbarWidgetColor: AppColors.primary,
          backgroundColor: AppColors.bg,
          activeControlsWidgetColor: AppColors.primary,
          initAspectRatio: CropAspectRatioPreset.square,
          lockAspectRatio: true,
          cropFrameColor: AppColors.primary,
        ),
        IOSUiSettings(title: 'Crop photo', aspectRatioLockEnabled: true),
      ],
    );
    if (cropped == null) return;
    final bytes = await File(cropped.path).readAsBytes();
    // Profile photos stay small and live in the profile itself, so they never expire.
    await UserService.instance.updateProfile(widget.me.uid, photoUrl: 'data:image/jpeg;base64,${base64Encode(bytes)}');
    if (mounted) showSnack(context, 'Photo updated');
  }

  Future<void> _editName(String current) async {
    final controller = TextEditingController(text: current);
    final name = await showDialog<String>(
      context: context,
      builder: (d) => AlertDialog(
        title: const Text('Your name'),
        content: TextField(controller: controller, autofocus: true, maxLength: 40, textCapitalization: TextCapitalization.words),
        actions: [
          TextButton(onPressed: () => Navigator.pop(d), child: const Text('Cancel', style: TextStyle(color: AppColors.textMuted))),
          TextButton(onPressed: () => Navigator.pop(d, controller.text), child: const Text('Save')),
        ],
      ),
    );
    if (name != null && name.trim().length >= 2) {
      await UserService.instance.updateProfile(widget.me.uid, name: name);
    }
  }

  Future<void> _checkUpdates() async {
    setState(() => _checking = true);
    final release = await UpdateService.newerRelease();
    if (!mounted) return;
    setState(() => _checking = false);
    if (release == null) {
      showSnack(context, 'You have the latest version');
    } else {
      showUpdateSheet(context, release);
    }
  }

  Future<void> _toggleLock(bool on) async {
    if (on && !await AppLock.instance.available()) {
      if (mounted) showSnack(context, 'Set a screen lock on your phone first (Settings > Security)', error: true);
      return;
    }
    final done = await AppLock.instance.setEnabled(on);
    if (done && mounted) showSnack(context, on ? 'Comms will ask for your fingerprint or screen lock' : 'App lock is off');
  }

  Future<void> _signOut() async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (d) => AlertDialog(
        title: const Text('Sign out?'),
        content: Text(kIsWeb
            ? 'This browser will forget your account and its encryption key. Your phone keeps working.'
            : 'You will stop getting messages and calls on this phone until you sign in again.'),
        actions: [
          TextButton(onPressed: () => Navigator.pop(d, false), child: const Text('Cancel', style: TextStyle(color: AppColors.textMuted))),
          TextButton(onPressed: () => Navigator.pop(d, true), child: const Text('Sign out', style: TextStyle(color: AppColors.error))),
        ],
      ),
    );
    if (ok == true) await AuthService.instance.signOut();
  }

  @override
  Widget build(BuildContext context) {
    return SafeArea(
      bottom: false,
      child: StreamBuilder<UserModel?>(
        stream: _meStream,
        initialData: widget.me,
        builder: (context, snap) {
          final me = snap.data ?? widget.me;
          return ListView(
            padding: const EdgeInsets.only(bottom: 120),
            children: [
              const PageHeader(title: 'Settings'),
              Center(
                child: ConstrainedBox(
                  constraints: const BoxConstraints(maxWidth: 560),
                  child: Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 16),
                    child: Column(
                      children: [
                        const SizedBox(height: 8),
                        TapScale(
                          onTap: _changePhoto,
                          child: Stack(
                            children: [
                              Avatar(name: me.name, photoUrl: me.photoUrl, size: 112),
                              Positioned(
                                right: 2,
                                bottom: 2,
                                child: Container(
                                  padding: const EdgeInsets.all(8),
                                  decoration: BoxDecoration(color: AppColors.primary, shape: BoxShape.circle, border: Border.all(color: AppColors.bg, width: 3)),
                                  child: const Icon(Icons.camera_alt_rounded, size: 18, color: AppColors.textDark),
                                ),
                              ),
                            ],
                          ),
                        ),
                        const SizedBox(height: 14),
                        Text(me.name, style: AppTheme.display(26), textAlign: TextAlign.center),
                        Text(me.email, style: AppTheme.body(14, color: AppColors.textMuted)),
                        const SizedBox(height: 24),
                        if (kIsWeb)
                          _Group(children: [
                            _Row(
                              icon: Icons.android_rounded,
                              title: 'Get Comms for Android',
                              value: 'Free',
                              onTap: () => launchUrl(Uri.parse('https://joepaul.vercel.app/downloads/Comms.apk')),
                            ),
                          ])
                        else
                        _Group(children: [
                          _Row(
                            icon: Icons.system_update_rounded,
                            title: 'Check for updates',
                            value: _info == null ? '' : 'Version ${_info!.version}',
                            trailing: _checking
                                ? const SizedBox(width: 18, height: 18, child: CircularProgressIndicator(strokeWidth: 2))
                                : _updateWaiting
                                    ? Container(
                                        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
                                        decoration: BoxDecoration(color: AppColors.primary, borderRadius: BorderRadius.circular(12)),
                                        child: Text('Update available', style: AppTheme.body(11.5, weight: FontWeight.w700, color: AppColors.textDark)),
                                      )
                                    : null,
                            onTap: _checking ? null : _checkUpdates,
                          ),
                        ]),
                        const SizedBox(height: 14),
                        _Group(children: [
                          _Row(icon: Icons.badge_rounded, title: 'Name', value: me.name, onTap: () => _editName(me.name)),
                          _Row(icon: Icons.photo_camera_back_rounded, title: 'Profile photo', value: 'Change', onTap: _changePhoto),
                        ]),
                        const SizedBox(height: 14),
                        _Group(children: [
                          if (kIsWeb)
                            _Row(
                              icon: Icons.notifications_active_rounded,
                              title: 'Notifications',
                              value: _notifications ? 'On' : 'Off',
                              trailing: Switch(value: _notifications, onChanged: _notifications ? null : (_) => _askForNotifications()),
                              onTap: _notifications ? null : _askForNotifications,
                            )
                          else
                          ListenableBuilder(
                            listenable: AppLock.instance,
                            builder: (context, _) => _Row(
                              icon: Icons.fingerprint_rounded,
                              title: 'App lock',
                              value: 'Fingerprint or screen lock',
                              trailing: Switch(value: AppLock.instance.enabled, onChanged: _toggleLock),
                              onTap: () => _toggleLock(!AppLock.instance.enabled),
                            ),
                          ),
                          const _Row(
                            icon: Icons.lock_rounded,
                            title: 'End-to-end encrypted',
                            value: 'Only your chats can read them',
                            trailing: SizedBox.shrink(),
                          ),
                        ]),
                        if (!kIsWeb) ...[
                          const SizedBox(height: 14),
                          _Group(children: [
                            _Row(
                              icon: Icons.settings_voice_rounded,
                              title: 'Walkie-talkie',
                              value: _walkie ? 'On' : 'Off',
                              trailing: Switch(value: _walkie, onChanged: _toggleWalkie),
                              onTap: () => _toggleWalkie(!_walkie),
                            ),
                          ]),
                          Padding(
                            padding: const EdgeInsets.fromLTRB(16, 8, 16, 0),
                            child: Text(
                              'When on, people can hold your chat and talk: it plays out loud through your speaker or headphones. '
                              'Stays quiet while your phone is on silent, vibrate or Do Not Disturb.',
                              style: AppTheme.body(12.5, color: AppColors.textFaint, height: 1.45),
                            ),
                          ),
                        ],
                        if (!kIsWeb) const SizedBox(height: 14),
                        if (!kIsWeb)
                        _Group(children: [
                          _Row(
                            icon: Icons.wifi_tethering_rounded,
                            title: 'Nearby chat',
                            value: 'No internet needed',
                            onTap: () => Navigator.of(context).push(MaterialPageRoute(builder: (_) => const OfflineLobbyScreen())),
                          ),
                        ]),
                        const SizedBox(height: 14),
                        _Group(children: [
                          _Row(icon: Icons.logout_rounded, title: 'Sign out', danger: true, onTap: _signOut),
                        ]),
                        const SizedBox(height: 24),
                        Text(
                            kIsWeb
                                ? 'Photos, videos and voice notes are kept in this browser.\nThe online copy is deleted after an hour.'
                                : 'Photos, videos and voice notes are kept on your phone.\nThe online copy is deleted after an hour.',
                            textAlign: TextAlign.center, style: AppTheme.body(12.5, color: AppColors.textFaint, height: 1.5)),
                      ],
                    ),
                  ),
                ),
              ),
            ],
          );
        },
      ),
    );
  }
}

class _Group extends StatelessWidget {
  final List<Widget> children;
  const _Group({required this.children});

  @override
  Widget build(BuildContext context) {
    return Container(
      decoration: BoxDecoration(color: AppColors.bgCard, borderRadius: BorderRadius.circular(20), border: Border.all(color: AppColors.border)),
      clipBehavior: Clip.antiAlias,
      child: Column(
        children: [
          for (var i = 0; i < children.length; i++) ...[
            if (i > 0) const Divider(indent: 56),
            children[i],
          ],
        ],
      ),
    );
  }
}

class _Row extends StatelessWidget {
  final IconData icon;
  final String title;
  final String value;
  final VoidCallback? onTap;
  final bool danger;
  final Widget? trailing;
  const _Row({required this.icon, required this.title, this.value = '', this.onTap, this.danger = false, this.trailing});

  @override
  Widget build(BuildContext context) {
    final color = danger ? AppColors.error : AppColors.text;
    return InkWell(
      onTap: onTap,
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 15),
        child: Row(
          children: [
            Icon(icon, color: danger ? AppColors.error : AppColors.primary, size: 22),
            const SizedBox(width: 18),
            Expanded(child: Text(title, style: AppTheme.body(15.5, weight: FontWeight.w600, color: color))),
            if (value.isNotEmpty)
              Flexible(child: Text(value, overflow: TextOverflow.ellipsis, style: AppTheme.body(13.5, color: AppColors.textMuted))),
            const SizedBox(width: 6),
            trailing ?? (danger ? const SizedBox.shrink() : const Icon(Icons.chevron_right_rounded, color: AppColors.textFaint)),
          ],
        ),
      ),
    );
  }
}
