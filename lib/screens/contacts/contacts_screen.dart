import 'dart:async';
import 'package:flutter/material.dart';
import '../../models/user_model.dart';
import '../../services/user_service.dart';
import '../../theme/app_colors.dart';
import '../../theme/app_theme.dart';
import '../../widgets/avatar.dart';
import '../../widgets/ui.dart';
import 'person_profile_screen.dart';
import '../../services/local_prefs.dart';

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
            title: Text(Nicknames.instance.name(u.uid, u.name), style: AppTheme.body(15.5, weight: FontWeight.w600)),
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
  return openProfile(context, me: me, person: person, onMessage: (p) {
    Navigator.of(context).pop();
    onMessage(p);
  });
}

