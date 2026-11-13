import 'dart:async';
import 'package:flutter/material.dart';
import '../../models/call_model.dart';
import '../../models/user_model.dart';
import '../../services/call_service.dart';
import '../../services/user_service.dart';
import '../../theme/app_colors.dart';
import '../../theme/app_theme.dart';
import '../../widgets/avatar.dart';
import '../../widgets/ui.dart';

class ContactsScreen extends StatefulWidget {
  final UserModel me;
  final ValueChanged<UserModel> onMessage;
  final bool focusSearch;
  const ContactsScreen({super.key, required this.me, required this.onMessage, this.focusSearch = false});

  @override
  State<ContactsScreen> createState() => _ContactsScreenState();
}

class _ContactsScreenState extends State<ContactsScreen> {
  final TextEditingController _search = TextEditingController();
  late final Stream<List<UserModel>> _contacts = UserService.instance.contacts(widget.me.uid);
  Timer? _debounce;
  List<UserModel>? _results;
  bool _searching = false;

  void _onChanged(String q) {
    _debounce?.cancel();
    if (q.trim().length < 2) {
      setState(() {
        _results = null;
        _searching = false;
      });
      return;
    }
    setState(() => _searching = true);
    _debounce = Timer(const Duration(milliseconds: 350), () async {
      final found = await UserService.instance.search(q, excludeUid: widget.me.uid).catchError((_) => <UserModel>[]);
      if (mounted && _search.text == q) {
        setState(() {
          _results = found;
          _searching = false;
        });
      }
    });
  }

  @override
  void dispose() {
    _debounce?.cancel();
    _search.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return SafeArea(
      bottom: false,
      child: Column(
        children: [
          const PageHeader(title: 'People', subtitle: 'Find anyone on Comms by name or email'),
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 4, 16, 8),
            child: SearchField(controller: _search, hint: 'Search people', onChanged: _onChanged),
          ),
          if (_searching) const LinearProgressIndicator(minHeight: 2),
          Expanded(
            child: _results != null
                ? (_results!.isEmpty
                    ? const EmptyState(icon: Icons.search_off_rounded, title: 'Nobody found', message: 'Check the spelling, or try their email address.')
                    : _list(_results!, searchResults: true))
                : StreamBuilder<List<UserModel>>(
                    stream: _contacts,
                    builder: (context, snap) {
                      if (!snap.hasData) return const Center(child: CircularProgressIndicator());
                      if (snap.data!.isEmpty) {
                        return const EmptyState(
                          icon: Icons.people_alt_outlined,
                          title: 'Your contacts live here',
                          message: 'Search for someone above, open their card and tap "Add contact".',
                        );
                      }
                      return _list(snap.data!);
                    },
                  ),
          ),
        ],
      ),
    );
  }

  Widget _list(List<UserModel> people, {bool searchResults = false}) {
    return ListView.builder(
      padding: const EdgeInsets.only(bottom: 120),
      itemCount: people.length,
      itemBuilder: (context, i) {
        final u = people[i];
        return FadeSlideIn(
          index: i,
          child: ListTile(
            contentPadding: const EdgeInsets.symmetric(horizontal: 20, vertical: 2),
            onTap: () => showPersonCard(context, me: widget.me, person: u, onMessage: widget.onMessage),
            leading: Avatar(name: u.name, photoUrl: u.photoUrl, size: 48, online: u.isOnline),
            title: Text(u.name, style: AppTheme.body(15.5, weight: FontWeight.w600)),
            subtitle: Text(u.email, style: AppTheme.body(13, color: AppColors.textMuted)),
            trailing: const Icon(Icons.chevron_right_rounded, color: AppColors.textFaint),
          ),
        );
      },
    );
  }
}

/// A person's card with quick actions.
Future<void> showPersonCard(BuildContext context, {required UserModel me, required UserModel person, required ValueChanged<UserModel> onMessage}) {
  return showModalBottomSheet(
    context: context,
    builder: (sheet) => StreamBuilder<UserModel?>(
      stream: UserService.instance.userStream(me.uid),
      initialData: me,
      builder: (_, snap) {
        final current = snap.data ?? me;
        final isContact = current.contacts.contains(person.uid);
        Future<void> call(CallType type) async {
          Navigator.pop(sheet);
          final error = await CallService.instance.startCall(me: current, other: person, type: type);
          if (error != null && context.mounted) showSnack(context, error, error: true);
        }

        return SafeArea(
          child: Padding(
            padding: const EdgeInsets.fromLTRB(24, 0, 24, 24),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Avatar(name: person.name, photoUrl: person.photoUrl, size: 84, online: person.isOnline),
                const SizedBox(height: 12),
                Text(person.name, style: AppTheme.display(24), textAlign: TextAlign.center),
                const SizedBox(height: 2),
                Text(person.email, style: AppTheme.body(14, color: AppColors.textMuted)),
                const SizedBox(height: 22),
                Row(
                  mainAxisAlignment: MainAxisAlignment.spaceEvenly,
                  children: [
                    _CardAction(icon: Icons.chat_bubble_rounded, label: 'Message', onTap: () {
                      Navigator.pop(sheet);
                      onMessage(person);
                    }),
                    _CardAction(icon: Icons.call_rounded, label: 'Voice', onTap: () => call(CallType.audio)),
                    _CardAction(icon: Icons.videocam_rounded, label: 'Video', onTap: () => call(CallType.video)),
                  ],
                ),
                const SizedBox(height: 18),
                SizedBox(
                  width: double.infinity,
                  child: OutlinedButton.icon(
                    style: OutlinedButton.styleFrom(
                      foregroundColor: isContact ? AppColors.textMuted : AppColors.primary,
                      side: BorderSide(color: isContact ? AppColors.border : AppColors.primary),
                      minimumSize: const Size.fromHeight(50),
                      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
                    ),
                    onPressed: () async {
                      if (isContact) {
                        await UserService.instance.removeContact(me.uid, person.uid);
                      } else {
                        await UserService.instance.addContact(me.uid, person.uid);
                      }
                    },
                    icon: Icon(isContact ? Icons.person_remove_rounded : Icons.person_add_alt_1_rounded),
                    label: Text(isContact ? 'Remove from contacts' : 'Add contact'),
                  ),
                ),
              ],
            ),
          ),
        );
      },
    ),
  );
}

class _CardAction extends StatelessWidget {
  final IconData icon;
  final String label;
  final VoidCallback onTap;
  const _CardAction({required this.icon, required this.label, required this.onTap});

  @override
  Widget build(BuildContext context) {
    return TapScale(
      onTap: onTap,
      child: Column(
        children: [
          Container(
            width: 62,
            height: 62,
            decoration: BoxDecoration(color: AppColors.primary, borderRadius: BorderRadius.circular(22)),
            child: Icon(icon, color: AppColors.textDark, size: 26),
          ),
          const SizedBox(height: 8),
          Text(label, style: AppTheme.body(13, weight: FontWeight.w600)),
        ],
      ),
    );
  }
}
