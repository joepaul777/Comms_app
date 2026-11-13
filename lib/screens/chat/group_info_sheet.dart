import 'package:flutter/material.dart';
import '../../models/chat_room_model.dart';
import '../../models/user_model.dart';
import '../../services/chat_service.dart';
import '../../services/user_service.dart';
import '../../theme/app_colors.dart';
import '../../theme/app_theme.dart';
import '../../widgets/avatar.dart';
import '../../widgets/ui.dart';
import 'create_group_screen.dart';

Future<void> showGroupInfo(BuildContext context, ChatRoomModel room, UserModel me) {
  return showModalBottomSheet(
    context: context,
    isScrollControlled: true,
    builder: (_) => DraggableScrollableSheet(
      expand: false,
      initialChildSize: 0.6,
      maxChildSize: 0.92,
      builder: (context, scroll) => _GroupInfo(room: room, me: me, scroll: scroll),
    ),
  );
}

class _GroupInfo extends StatelessWidget {
  final ChatRoomModel room;
  final UserModel me;
  final ScrollController scroll;
  const _GroupInfo({required this.room, required this.me, required this.scroll});

  bool get _isAdmin => room.adminId == me.uid;

  Future<void> _rename(BuildContext context) async {
    final controller = TextEditingController(text: room.groupName);
    final name = await showDialog<String>(
      context: context,
      builder: (d) => AlertDialog(
        title: const Text('Rename group'),
        content: TextField(controller: controller, autofocus: true, maxLength: 40),
        actions: [
          TextButton(onPressed: () => Navigator.pop(d), child: const Text('Cancel', style: TextStyle(color: AppColors.textMuted))),
          TextButton(onPressed: () => Navigator.pop(d, controller.text), child: const Text('Save')),
        ],
      ),
    );
    if (name != null && name.trim().isNotEmpty) await ChatService.instance.renameGroup(room.id, name);
  }

  Future<void> _addPeople(BuildContext context) async {
    final picked = await Navigator.of(context).push<List<String>>(
      MaterialPageRoute(builder: (_) => PeoplePickerScreen(me: me, exclude: room.participants, title: 'Add people')),
    );
    for (final uid in picked ?? const <String>[]) {
      await ChatService.instance.addMember(room.id, uid);
    }
  }

  Future<void> _leave(BuildContext context) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (d) => AlertDialog(
        title: const Text('Leave this group?'),
        content: const Text('You will stop getting its messages.'),
        actions: [
          TextButton(onPressed: () => Navigator.pop(d, false), child: const Text('Cancel', style: TextStyle(color: AppColors.textMuted))),
          TextButton(onPressed: () => Navigator.pop(d, true), child: const Text('Leave', style: TextStyle(color: AppColors.error))),
        ],
      ),
    );
    if (ok == true) {
      await ChatService.instance.removeMember(room.id, me.uid);
      if (context.mounted) Navigator.pop(context);
    }
  }

  @override
  Widget build(BuildContext context) {
    return FutureBuilder<List<UserModel>>(
      future: UserService.instance.getUsers(room.participants),
      builder: (context, snap) {
        final members = snap.data ?? const <UserModel>[];
        return ListView(
          controller: scroll,
          padding: const EdgeInsets.fromLTRB(20, 0, 20, 24),
          children: [
            Center(child: Avatar(name: room.groupName ?? 'Group', size: 72, group: true)),
            const SizedBox(height: 12),
            Center(child: Text(room.groupName ?? 'Group', style: AppTheme.display(24))),
            Center(child: Text('${room.participants.length} members', style: AppTheme.body(13.5, color: AppColors.textMuted))),
            const SizedBox(height: 18),
            Row(
              children: [
                if (_isAdmin) Expanded(child: _ActionChip(icon: Icons.edit_rounded, label: 'Rename', onTap: () => _rename(context))),
                if (_isAdmin) const SizedBox(width: 10),
                if (_isAdmin) Expanded(child: _ActionChip(icon: Icons.person_add_alt_1_rounded, label: 'Add', onTap: () => _addPeople(context))),
                if (_isAdmin) const SizedBox(width: 10),
                Expanded(child: _ActionChip(icon: Icons.logout_rounded, label: 'Leave', danger: true, onTap: () => _leave(context))),
              ],
            ),
            const SizedBox(height: 20),
            Text('MEMBERS', style: AppTheme.body(12, weight: FontWeight.w700, color: AppColors.textFaint)),
            const SizedBox(height: 8),
            if (!snap.hasData) const Padding(padding: EdgeInsets.all(24), child: Center(child: CircularProgressIndicator())),
            for (final m in members)
              ListTile(
                contentPadding: EdgeInsets.zero,
                leading: Avatar(name: m.name, photoUrl: m.photoUrl, size: 42, online: m.isOnline),
                title: Text(m.uid == me.uid ? '${m.name} (you)' : m.name, style: AppTheme.body(15, weight: FontWeight.w600)),
                subtitle: Text(m.uid == room.adminId ? 'Admin' : m.email, style: AppTheme.body(12.5, color: AppColors.textMuted)),
                trailing: _isAdmin && m.uid != me.uid
                    ? IconButton(
                        icon: const Icon(Icons.remove_circle_outline_rounded, color: AppColors.error),
                        tooltip: 'Remove',
                        onPressed: () async {
                          await ChatService.instance.removeMember(room.id, m.uid);
                          if (context.mounted) showSnack(context, '${m.firstName} removed');
                        },
                      )
                    : null,
              ),
          ],
        );
      },
    );
  }
}

class _ActionChip extends StatelessWidget {
  final IconData icon;
  final String label;
  final VoidCallback onTap;
  final bool danger;
  const _ActionChip({required this.icon, required this.label, required this.onTap, this.danger = false});

  @override
  Widget build(BuildContext context) {
    final color = danger ? AppColors.error : AppColors.primary;
    return TapScale(
      onTap: onTap,
      child: Container(
        padding: const EdgeInsets.symmetric(vertical: 14),
        decoration: BoxDecoration(
          color: color.withValues(alpha: 0.1),
          borderRadius: BorderRadius.circular(16),
          border: Border.all(color: color.withValues(alpha: 0.3)),
        ),
        child: Column(
          children: [
            Icon(icon, color: color),
            const SizedBox(height: 4),
            Text(label, style: AppTheme.body(13, weight: FontWeight.w600, color: color)),
          ],
        ),
      ),
    );
  }
}
