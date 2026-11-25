package com.comms.device;

import android.app.NotificationManager;
import android.content.Context;
import android.media.AudioManager;

import androidx.annotation.NonNull;

import io.flutter.embedding.engine.plugins.FlutterPlugin;
import io.flutter.plugin.common.MethodCall;
import io.flutter.plugin.common.MethodChannel;

/** Device checks for Comms, registered in every Flutter engine (also the one that handles pushes while the app is closed). */
public class CommsDevicePlugin implements FlutterPlugin, MethodChannel.MethodCallHandler {
    private MethodChannel channel;
    private Context context;

    @Override
    public void onAttachedToEngine(@NonNull FlutterPluginBinding binding) {
        context = binding.getApplicationContext();
        channel = new MethodChannel(binding.getBinaryMessenger(), "comms_device");
        channel.setMethodCallHandler(this);
    }

    @Override
    public void onDetachedFromEngine(@NonNull FlutterPluginBinding binding) {
        channel.setMethodCallHandler(null);
        channel = null;
    }

    @Override
    public void onMethodCall(@NonNull MethodCall call, @NonNull MethodChannel.Result result) {
        if ("soundOn".equals(call.method)) {
            result.success(soundOn());
        } else {
            result.notImplemented();
        }
    }

    /** The ringer is on (not silent or vibrate) and Do Not Disturb is off. */
    private boolean soundOn() {
        AudioManager audio = (AudioManager) context.getSystemService(Context.AUDIO_SERVICE);
        if (audio == null || audio.getRingerMode() != AudioManager.RINGER_MODE_NORMAL) return false;
        NotificationManager notifications = (NotificationManager) context.getSystemService(Context.NOTIFICATION_SERVICE);
        return notifications == null || notifications.getCurrentInterruptionFilter() == NotificationManager.INTERRUPTION_FILTER_ALL;
    }
}
