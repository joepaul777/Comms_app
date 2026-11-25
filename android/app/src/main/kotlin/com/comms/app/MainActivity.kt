package com.comms.app

import android.app.Activity
import android.app.KeyguardManager
import android.app.PictureInPictureParams
import android.content.res.Configuration
import android.util.Rational
import android.content.Context
import android.content.Intent
import android.os.Build
import android.os.Bundle
import android.view.WindowManager
import androidx.annotation.RequiresApi
import cl.puntito.simple_pip_mode.PipCallbackHelperActivityWrapper
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel

/**
 * The app only shows over the lock screen while a call is ringing or in progress.
 * At any other time, waking the phone shows the lock screen as normal.
 *
 * It also receives "send this message" requests from JACE (see AssistantSendActivity).
 */
class MainActivity : PipCallbackHelperActivityWrapper() {

    private var assistantChannel: MethodChannel? = null
    private var pendingAssistant: Map<String, String>? = null
    private var unlockResult: MethodChannel.Result? = null

    // Picture-in-picture during video calls: the call screen says when a call is live
    // and the shape of the other person's picture (wide from a laptop, tall from a phone).
    private var pipChannel: MethodChannel? = null
    private var pipReady = false
    private var pipRatio = Rational(9, 16)

    @RequiresApi(Build.VERSION_CODES.O)
    private fun pipParams(): PictureInPictureParams {
        val builder = PictureInPictureParams.Builder().setAspectRatio(pipRatio)
        if (Build.VERSION.SDK_INT >= 31) {
            // Android 12+: going home slides straight into the small window.
            builder.setAutoEnterEnabled(pipReady)
            builder.setSeamlessResizeEnabled(true)
        }
        return builder.build()
    }

    private fun enterPip(): Boolean {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.O || !pipReady) return false
        return try {
            enterPictureInPictureMode(pipParams())
        } catch (e: Exception) {
            false
        }
    }

    /** Android before 12 has no automatic entry: go into the small window when the person leaves. */
    override fun onUserLeaveHint() {
        super.onUserLeaveHint()
        if (Build.VERSION.SDK_INT in Build.VERSION_CODES.O until 31) enterPip()
    }

    override fun onPictureInPictureModeChanged(active: Boolean, newConfig: Configuration?) {
        super.onPictureInPictureModeChanged(active, newConfig)
        pipChannel?.invokeMethod("changed", active)
    }

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        if (isCallIntent(intent)) setOverLockScreen(this, true)
        takeAssistantRequest(intent)
    }

    override fun onNewIntent(intent: Intent) {
        super.onNewIntent(intent)
        if (isCallIntent(intent)) setOverLockScreen(this, true)
        takeAssistantRequest(intent)
    }

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        val messenger = flutterEngine.dartExecutor.binaryMessenger
        MethodChannel(messenger, "comms/lock_screen").setMethodCallHandler { call, result ->
            if (call.method == "setInCall") {
                setOverLockScreen(this, call.arguments as? Boolean ?: false)
                result.success(null)
            } else if (call.method == "setSecure") {
                // Blocks screenshots and screen recording (used while a view-once photo is open).
                if (call.arguments as? Boolean == true) {
                    window.addFlags(WindowManager.LayoutParams.FLAG_SECURE)
                } else {
                    window.clearFlags(WindowManager.LayoutParams.FLAG_SECURE)
                }
                result.success(null)
            } else if (call.method == "canLock") {
                result.success(keyguard().isDeviceSecure)
            } else if (call.method == "unlock") {
                askToUnlock(result)
            } else if (call.method == "hideInRecents") {
                // App lock: no peeking at chats from the recent-apps screen (Android 13+).
                if (Build.VERSION.SDK_INT >= 33) setRecentsScreenshotEnabled(call.arguments as? Boolean != true)
                result.success(null)
            } else {
                result.notImplemented()
            }
        }
        pipChannel = MethodChannel(messenger, "comms/pip").apply {
            setMethodCallHandler { call, result ->
                when (call.method) {
                    "setReady" -> {
                        pipReady = call.argument<Boolean>("ready") == true
                        val w = call.argument<Int>("width") ?: 9
                        val h = call.argument<Int>("height") ?: 16
                        // Android only allows shapes between 1:2.39 and 2.39:1.
                        val ratio = (w.toDouble() / h.toDouble()).coerceIn(1 / 2.39 + 0.01, 2.39 - 0.01)
                        pipRatio = Rational((ratio * 1000).toInt(), 1000)
                        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
                            try {
                                setPictureInPictureParams(pipParams())
                            } catch (_: Exception) {}
                        }
                        result.success(null)
                    }
                    "enter" -> result.success(enterPip())
                    "isActive" -> result.success(Build.VERSION.SDK_INT >= Build.VERSION_CODES.N && isInPictureInPictureMode)
                    // The call ended while in the small window: put Comms away rather than
                    // leaving a tiny chat list floating on the screen.
                    "close" -> {
                        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.N && isInPictureInPictureMode) moveTaskToBack(false)
                        result.success(null)
                    }
                    else -> result.notImplemented()
                }
            }
        }
        assistantChannel = MethodChannel(messenger, "comms/assistant").apply {
            setMethodCallHandler { call, result ->
                if (call.method == "takePending") {
                    result.success(pendingAssistant)
                    pendingAssistant = null
                } else {
                    result.notImplemented()
                }
            }
        }
    }

    private fun keyguard() = getSystemService(Context.KEYGUARD_SERVICE) as KeyguardManager

    /** Shows the phone's own lock screen check (fingerprint, face, PIN or pattern). */
    private fun askToUnlock(result: MethodChannel.Result) {
        if (!keyguard().isDeviceSecure) {
            result.success(true)
            return
        }
        @Suppress("DEPRECATION")
        val intent = keyguard().createConfirmDeviceCredentialIntent("Unlock Comms", "Confirm it's you")
        if (intent == null) {
            result.success(true)
            return
        }
        unlockResult?.success(false)
        unlockResult = result
        @Suppress("DEPRECATION")
        startActivityForResult(intent, REQUEST_UNLOCK)
    }

    @Deprecated("Still the way to get the lock screen check's answer")
    override fun onActivityResult(requestCode: Int, resultCode: Int, data: Intent?) {
        @Suppress("DEPRECATION")
        super.onActivityResult(requestCode, resultCode, data)
        if (requestCode == REQUEST_UNLOCK) {
            unlockResult?.success(resultCode == Activity.RESULT_OK)
            unlockResult = null
        }
    }

    private fun takeAssistantRequest(intent: Intent?) {
        if (intent?.action != ACTION_ASSISTANT_SEND) return
        val request = mapOf(
            "name" to intent.getStringExtra(AssistantSendActivity.EXTRA_NAME).orEmpty(),
            "text" to intent.getStringExtra(AssistantSendActivity.EXTRA_TEXT).orEmpty(),
        )
        intent.action = null // handle it once
        val channel = assistantChannel
        if (channel != null) {
            channel.invokeMethod("request", request)
        } else {
            pendingAssistant = request
        }
    }

    // An incoming-call notification opens the app with "call|<id>" as its payload.
    private fun isCallIntent(intent: Intent?): Boolean =
        intent?.getStringExtra("payload")?.startsWith("call|") == true

    companion object {
        const val ACTION_ASSISTANT_SEND = "com.comms.app.internal.ASSISTANT_SEND"
        private const val REQUEST_UNLOCK = 4711

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
