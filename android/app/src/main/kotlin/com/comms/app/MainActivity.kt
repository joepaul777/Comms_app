package com.comms.app

import android.app.Activity
import android.content.Intent
import android.os.Build
import android.os.Bundle
import android.view.WindowManager
import cl.puntito.simple_pip_mode.PipCallbackHelperActivityWrapper
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel

/**
 * The app only shows over the lock screen while a call is ringing or in progress.
 * At any other time, waking the phone shows the lock screen as normal.
 */
class MainActivity : PipCallbackHelperActivityWrapper() {

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        if (isCallIntent(intent)) setOverLockScreen(this, true)
    }

    override fun onNewIntent(intent: Intent) {
        super.onNewIntent(intent)
        if (isCallIntent(intent)) setOverLockScreen(this, true)
    }

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, "comms/lock_screen").setMethodCallHandler { call, result ->
            if (call.method == "setInCall") {
                setOverLockScreen(this, call.arguments as? Boolean ?: false)
                result.success(null)
            } else {
                result.notImplemented()
            }
        }
    }

    // An incoming-call notification opens the app with "call|<id>" as its payload.
    private fun isCallIntent(intent: Intent?): Boolean =
        intent?.getStringExtra("payload")?.startsWith("call|") == true

    companion object {
        fun setOverLockScreen(activity: Activity, on: Boolean) {
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O_MR1) {
                activity.setShowWhenLocked(on)
                activity.setTurnScreenOn(on)
            } else {
                @Suppress("DEPRECATION")
                val flags = WindowManager.LayoutParams.FLAG_SHOW_WHEN_LOCKED or WindowManager.LayoutParams.FLAG_TURN_SCREEN_ON
                if (on) activity.window.addFlags(flags) else activity.window.clearFlags(flags)
            }
        }
    }
}
