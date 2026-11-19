import 'package:flutter/material.dart';
import 'package:intl/intl.dart';
import '../../models/call_model.dart';
import '../../models/user_model.dart';
import '../../services/call_service.dart';
import '../../services/chat_service.dart';
import '../../services/e2e_service.dart';
import '../../services/local_prefs.dart';
import '../../services/user_service.dart';
import '../../theme/app_colors.dart';
import '../../theme/app_theme.dart';
import '../../utils/image_utils.dart';
import '../../widgets/avatar.dart';
import '../../widgets/full_screen_image_viewer.dart';
import '../../widgets/ui.dart';

/// Opens someone's profile.
Future<void> openProfile(BuildContext context, {required UserModel me, required UserModel person, required ValueChanged<UserModel> onMessage}) {
  return Navigator.of(context).push(MaterialPageRoute(builder: (_) => PersonProfileScreen(me: me, person: person, onMessage: onMessage)));
}

/// Another person's profile: their photo, name, status, and ways to reach them.
class PersonProfileScreen extends StatefulWidget {
  final UserModel me;
  final UserModel person;
  final ValueChanged<UserModel> onMessage;
  const PersonProfileScreen({super.key, required this.me, required this.person, required this.onMessage});

  @override
  State<PersonProfileScreen> createState() => _PersonProfileScreenState();
}

class _PersonProfileScreenState extends State<PersonProfileScreen> {
  late final Stream<UserModel?> _person = UserService.instance.userStream(widget.person.uid);
  late final Stream<UserModel?> _me = UserService.instance.userStream(widget.me.uid);

  Future<void> _call(UserModel person, CallType type) async {
    final error = await CallService.instance.startCall(me: ChatService.instance.me ?? widget.me, other: person, type: type);
    if (error != null && mounted) showSnack(context, error, error: true);
  }

  void _viewPhoto(UserModel person) {
    if (person.photoUrl.isEmpty) return;
    Navigator.of(context).push(PageRouteBuilder(
      opaque: false,
      barrierColor: Colors.black,
      pageBuilder: (_, _, _) => FullScreenImageViewer(imageProvider: getImageProvider(person.photoUrl), heroTag: 'profile-${person.uid}'),
      transitionsBuilder: (_, a, _, child) => FadeTransition(opacity: a, child: child),
    ));
  }

  Future<void> _editNickname(UserModel p) async {
    final controller = TextEditingController(text: Nicknames.instance.of(p.uid) ?? '');
    final result = await showDialog<String>(
      context: context,
      builder: (d) => AlertDialog(
        title: const Text('Nickname'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text('Only you will see this name. ${p.firstName} won\'t know.', style: AppTheme.body(13.5, color: AppColors.textMuted)),
            const SizedBox(height: 12),
            TextField(
              controller: controller,
              autofocus: true,
              maxLength: 40,
              textCapitalization: TextCapitalization.words,
              decoration: InputDecoration(hintText: p.name),
              onSubmitted: (v) => Navigator.pop(d, v),
            ),
          ],
        ),
        actions: [
          if (Nicknames.instance.of(p.uid) != null)
            TextButton(onPressed: () => Navigator.pop(d, ''), child: const Text('Remove', style: TextStyle(color: AppColors.error))),
          TextButton(onPressed: () => Navigator.pop(d), child: const Text('Cancel', style: TextStyle(color: AppColors.textMuted))),
          TextButton(onPressed: () => Navigator.pop(d, controller.text), child: const Text('Save')),
        ],
      ),
    );
    if (result == null) return;
    await Nicknames.instance.set(p.uid, result);
    if (mounted) setState(() {});
  }

  /// Shows the code both people can compare to be sure their messages are private.
  Future<void> _showSecurityCode(UserModel p) async {
    final mine = E2E.instance.publicKey;
    final theirs = p.publicKey;
    if (mine == null || theirs == null) {
      showSnack(context, '${p.firstName} needs to update Comms for encrypted messages');
      return;
    }
    final code = await E2E.securityCode(mine, theirs);
    if (!mounted) return;
    final groups = code.split(' ');
    await showDialog<void>(
      context: context,
      builder: (d) => AlertDialog(
        title: const Text('Security code'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              'Your messages with ${p.firstName} are end-to-end encrypted. To be sure nobody is in between, '
              'check that ${p.firstName} sees the same numbers on their phone (in person, or on a call).',
              style: AppTheme.body(13.5, color: AppColors.textMuted),
            ),
            const SizedBox(height: 16),
            Container(
              padding: const EdgeInsets.all(14),
              decoration: BoxDecoration(color: AppColors.bg, borderRadius: BorderRadius.circular(14), border: Border.all(color: AppColors.border)),
              child: Column(
                children: [
                  for (var row = 0; row < 3; row++)
                    Padding(
                      padding: const EdgeInsets.symmetric(vertical: 4),
                      child: Row(
                        mainAxisAlignment: MainAxisAlignment.spaceBetween,
                        children: [
                          for (var col = 0; col < 4; col++)
                            Text(groups[row * 4 + col], style: const TextStyle(fontFamily: 'monospace', fontSize: 16, letterSpacing: 1.5, color: AppColors.text)),
                        ],
                      ),
                    ),
                ],
              ),
            ),
            const SizedBox(height: 12),
            Text('The code changes if either of you reinstalls Comms or moves to a new phone.', style: AppTheme.body(12.5, color: AppColors.textFaint)),
          ],
        ),
        actions: [TextButton(onPressed: () => Navigator.pop(d), child: const Text('Done'))],
      ),
    );
  }

  String _status(UserModel p) {
    if (p.isBusy) return 'On a call';
    if (p.isOnline) return 'Online';
    final t = p.lastSeen;
    final now = DateTime.now();
    if (now.difference(t).inMinutes < 1) return 'Last seen just now';
    if (DateUtils.isSameDay(now, t)) return 'Last seen today at ${DateFormat.jm().format(t)}';
    if (now.difference(t).inDays < 7) return 'Last seen ${DateFormat.E().format(t)} at ${DateFormat.jm().format(t)}';
    return 'Last seen ${DateFormat.yMMMd().format(t)}';
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: AppColors.bg,
      appBar: AppBar(backgroundColor: Colors.transparent, elevation: 0),
      extendBodyBehindAppBar: true,
      body: StreamBuilder<UserModel?>(
        stream: _person,
        initialData: UserService.instance.cached(widget.person.uid) ?? widget.person,
        builder: (context, snap) {
          final p = snap.data ?? widget.person;
          final status = _status(p);
          return Container(
            decoration: const BoxDecoration(
              gradient: RadialGradient(center: Alignment(0, -1.2), radius: 1.3, colors: [Color(0x26FACC15), Color(0x00000000)]),
            ),
            child: SafeArea(
              child: Center(
                child: ConstrainedBox(
                  constraints: const BoxConstraints(maxWidth: 520),
                  child: ListView(
                    padding: const EdgeInsets.fromLTRB(20, 24, 20, 32),
                    children: [
                      FadeSlideIn(
                        child: Center(
                          child: GestureDetector(
                            onTap: () => _viewPhoto(p),
                            child: Hero(tag: 'profile-${p.uid}', child: Avatar(name: p.name, photoUrl: p.photoUrl, size: 132)),
                          ),
                        ),
                      ),
                      const SizedBox(height: 16),
                      Text(Nicknames.instance.name(p.uid, p.name), textAlign: TextAlign.center, style: AppTheme.display(28, weight: FontWeight.w700)),
                      if (Nicknames.instance.of(p.uid) != null)
                        Text('~ ${p.name}', textAlign: TextAlign.center, style: AppTheme.body(13.5, color: AppColors.textMuted)),
                      const SizedBox(height: 4),
                      AnimatedSwitcher(
                        duration: const Duration(milliseconds: 250),
                        child: Row(
                          key: ValueKey(status),
                          mainAxisAlignment: MainAxisAlignment.center,
                          children: [
                            if (p.isOnline || p.isBusy)
                              Container(
                                width: 8,
                                height: 8,
                                margin: const EdgeInsets.only(right: 6),
                                decoration: BoxDecoration(color: p.isBusy ? AppColors.primary : AppColors.online, shape: BoxShape.circle),
                              ),
                            Text(status, style: AppTheme.body(14, color: p.isOnline ? AppColors.online : AppColors.textMuted)),
                          ],
                        ),
                      ),
                      const SizedBox(height: 28),
                      FadeSlideIn(
                        index: 1,
                        child: Row(
                          children: [
                            _Action(icon: Icons.chat_bubble_rounded, label: 'Message', onTap: () => widget.onMessage(p)),
                            const SizedBox(width: 12),
                            _Action(icon: Icons.call_rounded, label: 'Voice', onTap: () => _call(p, CallType.audio)),
                            const SizedBox(width: 12),
                            _Action(icon: Icons.videocam_rounded, label: 'Video', onTap: () => _call(p, CallType.video)),
                          ],
                        ),
                      ),
                      const SizedBox(height: 22),
                      FadeSlideIn(
                        index: 2,
                        child: Container(
                          decoration: BoxDecoration(
                            color: AppColors.bgCard,
                            borderRadius: BorderRadius.circular(20),
                            border: Border.all(color: AppColors.border),
                          ),
                          child: Column(
                            children: [
                              ListTile(
                                leading: const Icon(Icons.edit_rounded, color: AppColors.primary),
                                title: Text('Nickname', style: AppTheme.body(12.5, color: AppColors.textMuted)),
                                subtitle: Text(
                                  Nicknames.instance.of(p.uid) ?? 'Add a name only you will see',
                                  style: AppTheme.body(15, color: Nicknames.instance.of(p.uid) == null ? AppColors.textFaint : AppColors.text),
                                ),
                                trailing: const Icon(Icons.chevron_right_rounded, color: AppColors.textFaint),
                                onTap: () => _editNickname(p),
                              ),
                              const Divider(indent: 56, height: 1),
                              ListTile(
                                leading: Icon(p.publicKey != null ? Icons.lock_rounded : Icons.lock_open_rounded, color: p.publicKey != null ? AppColors.primary : AppColors.textMuted),
                                title: Text('Encryption', style: AppTheme.body(12.5, color: AppColors.textMuted)),
                                subtitle: Text(
                                  p.publicKey != null ? 'Messages are end-to-end encrypted. Tap to verify.' : 'Needs to update Comms for encrypted messages',
                                  style: AppTheme.body(15),
                                ),
                                trailing: const Icon(Icons.chevron_right_rounded, color: AppColors.textFaint),
                                onTap: () => _showSecurityCode(p),
                              ),
                              const Divider(indent: 56, height: 1),
                              ListTile(
                                leading: const Icon(Icons.alternate_email_rounded, color: AppColors.primary),
                                title: Text('Email', style: AppTheme.body(12.5, color: AppColors.textMuted)),
                                subtitle: Text(p.email, style: AppTheme.body(15)),
                              ),
                              const Divider(indent: 56, height: 1),
                              StreamBuilder<UserModel?>(
                                stream: _me,
                                initialData: widget.me,
                                builder: (context, meSnap) {
                                  final me = meSnap.data ?? widget.me;
                                  final isContact = me.contacts.contains(p.uid);
                                  return ListTile(
                                    leading: Icon(
                                      isContact ? Icons.person_remove_rounded : Icons.person_add_alt_1_rounded,
                                      color: isContact ? AppColors.textMuted : AppColors.primary,
                                    ),
                                    title: Text(isContact ? 'Remove from contacts' : 'Add to contacts', style: AppTheme.body(15)),
                                    onTap: () async {
                                      if (isContact) {
                                        await UserService.instance.removeContact(me.uid, p.uid);
                                      } else {
                                        await UserService.instance.addContact(me.uid, p.uid);
                                      }
                                      if (context.mounted) showSnack(context, isContact ? 'Removed from contacts' : 'Added to contacts');
                                    },
                                  );
                                },
                              ),
                            ],
                          ),
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            ),
          );
        },
      ),
    );
  }
}

class _Action extends StatelessWidget {
  final IconData icon;
  final String label;
  final VoidCallback onTap;
  const _Action({required this.icon, required this.label, required this.onTap});

  @override
  Widget build(BuildContext context) {
    return Expanded(
      child: TapScale(
        onTap: onTap,
        child: Container(
          padding: const EdgeInsets.symmetric(vertical: 16),
          decoration: BoxDecoration(
            color: AppColors.primarySoft,
            borderRadius: BorderRadius.circular(20),
            border: Border.all(color: AppColors.primary.withValues(alpha: 0.25)),
          ),
          child: Column(
            children: [
              Icon(icon, color: AppColors.primary, size: 26),
              const SizedBox(height: 6),
              Text(label, style: AppTheme.body(13, weight: FontWeight.w600, color: AppColors.primary)),
            ],
          ),
        ),
      ),
    );
  }
}
