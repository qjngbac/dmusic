package com.dmusic.app.dmusic_app

import android.content.Intent
import android.os.Bundle
import com.ryanheise.audioservice.AudioServiceActivity

/** The service owns the shared engine; closing its UI must not destroy playback. */
class MainActivity : AudioServiceActivity() {
    override fun shouldDestroyEngineWithHost(): Boolean = false

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        handleIntent(intent)
    }

    override fun onNewIntent(intent: Intent) {
        super.onNewIntent(intent)
        handleIntent(intent)
    }

    override fun onDestroy() {
        try {
            DMusicEngineBridge.onActivityFinishing(this)
        } finally {
            super.onDestroy()
        }
    }

    private fun handleIntent(intent: Intent?) {
        val action = intent?.getStringExtra("widget_action") ?: return
        intent.removeExtra("widget_action")
        DMusicEngineBridge.dispatchAction(action)
    }
}
