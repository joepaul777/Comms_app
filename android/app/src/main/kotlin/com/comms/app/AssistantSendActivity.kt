package com.comms.app

import android.app.Activity
import android.content.Intent
import android.os.Bundle

/**
 * The door JACE uses to ask Comms to send a message. Only apps signed with the same key
 * as Comms (i.e. JACE) hold the permission needed to open it. It shows nothing itself:
 * it hands the request to the main app and closes.
 */
class AssistantSendActivity : Activity() {
    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        val name = intent.getStringExtra(EXTRA_NAME).orEmpty().take(80)
        val text = intent.getStringExtra(EXTRA_TEXT).orEmpty().take(4000)
        if (name.isNotBlank()) {
            startActivity(Intent(this, MainActivity::class.java).apply {
                action = MainActivity.ACTION_ASSISTANT_SEND
                putExtra(EXTRA_NAME, name)
                putExtra(EXTRA_TEXT, text)
                addFlags(Intent.FLAG_ACTIVITY_NEW_TASK or Intent.FLAG_ACTIVITY_SINGLE_TOP)
            })
        }
        finish()
    }

    companion object {
        const val EXTRA_NAME = "name"
        const val EXTRA_TEXT = "text"
    }
}
