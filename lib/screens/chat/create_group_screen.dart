import 'package:flutter/material.dart';
import '../../models/chat_room_model.dart';
import '../../models/user_model.dart';
import '../../services/chat_service.dart';
import '../../services/rate_limiter.dart';
import '../../services/user_service.dart';
import '../../theme/app_colors.dart';
import '../../theme/app_theme.dart';
import '../../widgets/avatar.dart';
import '../../widgets/ui.dart';

/// Pick people from your contacts (or by search). Returns their uids.
class PeoplePickerScreen extends StatefulWidget {
  final UserModel me;
  final List<String> exclude;
  final String title;
  final bool askForGroupName;
  const PeoplePickerScreen({super.key, required this.me, this.exclude = const [], required this.title, this.askForGroupName = false});

  @override
  State<PeoplePickerScreen> createState() => _PeoplePickerScreenState();
}

class _PeoplePickerScreenState extends State<PeoplePickerScreen> {
  final TextEditingController _search = TextEditingController();
  final TextEditingController _name = TextEditingController();
  final Map<String, UserModel> _selected = {};
  List<UserModel>? _results;
  bool _creating = false;

  Future<void> _onSearch(String q) async {
    if (q.trim().length < 2) {
      setState(() => _results = null);
      return;
    }
    final found = await UserService.instance.search(q, excludeUid: widget.me.uid);
    if (mounted && _search.text == q) setState(() => _results = found);
  }

  Future<void> _done() async {
    if (_selected.isEmpty) return;
    if (!widget.askForGroupName) {
      Navigator.pop(context, _selected.keys.toList());
      return;
    }
    if (_name.text.trim().isEmpty) {
      showSnack(context, 'Give the group a name', error: true);
      return;
    }
    setState(() => _creating = true);
    try {
      final room = await ChatService.instance.createGroupChat(admin: widget.me, groupName: _name.text, memberIds: _selected.keys.toList());
      if (mounted) Navigator.pop<ChatRoomModel>(context, room);
    } on RateLimitException catch (e) {
      if (mounted) showSnack(context, e.message, error: true);
    } catch (_) {
      if (mounted) showSnack(context, 'Could not create the group', error: true);
    } finally {
      if (mounted) setState(() => _creating = false);
    }
  }

  Widget _personTile(UserModel u) {
    final picked = _selected.containsKey(u.uid);
    final blocked = widget.exclude.contains(u.uid);
    return ListTile(
      enabled: !blocked,
      onTap: () => setState(() => picked ? _selected.remove(u.uid) : _selected[u.uid] = u),
      leading: Avatar(name: u.name, photoUrl: u.photoUrl, size: 44),
      title: Text(u.name, style: AppTheme.body(15, weight: FontWeight.w600)),
      subtitle: Text(blocked ? 'Already in the group' : u.email, style: AppTheme.body(12.5, color: AppColors.textMuted)),
      trailing: AnimatedContainer(
        duration: const Duration(milliseconds: 180),
        width: 26,
        height: 26,
        decoration: BoxDecoration(
          shape: BoxShape.circle,
          color: picked ? AppColors.primary : Colors.transparent,
          border: Border.all(color: picked ? AppColors.primary : AppColors.borderLight, width: 2),
        ),
        child: picked ? const Icon(Icons.check_rounded, size: 16, color: AppColors.textDark) : null,
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: Text(widget.title)),
      floatingActionButton: AnimatedScale(
        scale: _selected.isEmpty ? 0 : 1,
        duration: const Duration(milliseconds: 220),
        curve: Curves.easeOutBack,
        child: FloatingActionButton.extended(
          backgroundColor: AppColors.primary,
          foregroundColor: AppColors.textDark,
          onPressed: _creating ? null : _done,
          icon: _creating
              ? const SizedBox(width: 18, height: 18, child: CircularProgressIndicator(strokeWidth: 2, color: AppColors.textDark))
              : const Icon(Icons.check_rounded),
          label: Text(widget.askForGroupName ? 'Create group' : 'Add ${_selected.length}'),
        ),
      ),
      body: Center(
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 640),
          child: Column(
            children: [
              if (widget.askForGroupName)
                Padding(
                  padding: const EdgeInsets.fromLTRB(16, 4, 16, 8),
                  child: TextField(
                    controller: _name,
                    maxLength: 40,
                    textCapitalization: TextCapitalization.words,
                    decoration: const InputDecoration(hintText: 'Group name', counterText: '', prefixIcon: Icon(Icons.groups_rounded, color: AppColors.primary)),
                  ),
                ),
              Padding(
                padding: const EdgeInsets.fromLTRB(16, 4, 16, 8),
                child: SearchField(controller: _search, hint: 'Search by name or email', onChanged: _onSearch),
              ),
              if (_selected.isNotEmpty)
                SizedBox(
                  height: 44,
                  child: ListView(
                    scrollDirection: Axis.horizontal,
                    padding: const EdgeInsets.symmetric(horizontal: 12),
                    children: _selected.values
                        .map((u) => Padding(
                              padding: const EdgeInsets.symmetric(horizontal: 4),
                              child: InputChip(
                                label: Text(u.firstName),
                                avatar: Avatar(name: u.name, photoUrl: u.photoUrl, size: 24),
                                onDeleted: () => setState(() => _selected.remove(u.uid)),
                                backgroundColor: AppColors.bgElevated,
                                side: const BorderSide(color: AppColors.border),
                              ),
                            ))
                        .toList(),
                  ),
                ),
              Expanded(
                child: _results != null
                    ? (_results!.isEmpty
                        ? const EmptyState(icon: Icons.search_off_rounded, title: 'Nobody found', message: 'Try their full email address.')
                        : ListView(children: _results!.map(_personTile).toList()))
                    : StreamBuilder<List<UserModel>>(
                        stream: UserService.instance.contacts(widget.me.uid),
                        builder: (context, snap) {
                          final people = snap.data ?? const <UserModel>[];
                          if (snap.hasData && people.isEmpty) {
                            return const EmptyState(icon: Icons.people_outline_rounded, title: 'No contacts yet', message: 'Search above to find people.');
                          }
                          return ListView(children: people.map(_personTile).toList());
                        },
                      ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
