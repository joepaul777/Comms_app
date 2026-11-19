/// The few things that work differently in the browser than on a phone: where files
/// live, how a stored photo, video or voice note is played, and the ringtone.
///
/// On a phone these are plain files on disk. In the browser there is no disk, so
/// files are kept by the browser itself (see platform_web.dart). Everything else in
/// the app is the same code on both.
library;

export 'platform_io.dart' if (dart.library.js_interop) 'platform_web.dart';
