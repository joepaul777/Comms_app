import 'package:flutter/material.dart';
import '../theme/app_colors.dart';
import '../theme/app_theme.dart';
import '../models/user_model.dart';
import '../services/user_service.dart';
import '../utils/image_utils.dart';

class Avatar extends StatelessWidget {
  final String name;
  final String photoUrl;
  final double size;
  final bool online;
  final bool group;
  const Avatar({super.key, required this.name, this.photoUrl = '', this.size = 48, this.online = false, this.group = false});

  String get _initials {
    final parts = name.trim().split(RegExp(r'\s+')).where((p) => p.isNotEmpty).toList();
    if (parts.length >= 2) return '${parts[0][0]}${parts[1][0]}'.toUpperCase();
    return parts.isNotEmpty ? parts[0][0].toUpperCase() : '?';
  }

  @override
  Widget build(BuildContext context) {
    final fallback = Center(
      child: group
          ? Icon(Icons.groups_rounded, color: AppColors.primary, size: size * 0.5)
          : Text(_initials, style: AppTheme.display(size * 0.36, color: AppColors.primary)),
    );
    return SizedBox(
      width: size,
      height: size,
      child: Stack(
        clipBehavior: Clip.none,
        children: [
          Container(
            width: size,
            height: size,
            decoration: BoxDecoration(
              shape: BoxShape.circle,
              color: AppColors.primarySoft,
              border: Border.all(color: AppColors.primary.withValues(alpha: 0.18)),
            ),
            clipBehavior: Clip.antiAlias,
            child: photoUrl.isEmpty
                ? fallback
                : Image(
                    // Decode at the size shown, not the full photo.
                    image: ResizeImage(getImageProvider(photoUrl), width: (size * MediaQuery.devicePixelRatioOf(context)).round(), policy: ResizeImagePolicy.fit),
                    fit: BoxFit.cover,
                    errorBuilder: (_, _, _) => fallback,
                  ),
          ),
          if (online)
            Positioned(
              right: 0,
              bottom: 0,
              child: Container(
                width: size * 0.27,
                height: size * 0.27,
                decoration: BoxDecoration(
                  color: AppColors.online,
                  shape: BoxShape.circle,
                  border: Border.all(color: AppColors.bg, width: 2.5),
                ),
              ),
            ),
        ],
      ),
    );
  }
}

/// Someone's picture looked up from their profile, so it is always their current one
/// (records like calls only keep a name, because photos are too big to copy into them).
class PersonAvatar extends StatelessWidget {
  final String uid;
  final String name;
  final String fallbackPhoto;
  final double size;
  const PersonAvatar({super.key, required this.uid, required this.name, this.fallbackPhoto = '', this.size = 48});

  @override
  Widget build(BuildContext context) {
    if (uid.isEmpty) return Avatar(name: name, photoUrl: fallbackPhoto, size: size);
    return StreamBuilder<UserModel?>(
      stream: UserService.instance.userStream(uid),
      initialData: UserService.instance.cached(uid),
      builder: (context, snap) {
        final photo = snap.data?.photoUrl ?? '';
        return Avatar(name: name, photoUrl: photo.isNotEmpty ? photo : fallbackPhoto, size: size);
      },
    );
  }
}
