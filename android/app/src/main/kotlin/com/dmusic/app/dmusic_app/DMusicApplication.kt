package com.dmusic.app.dmusic_app

import android.app.Application
import com.dmusic.runtimebridge.DMusicRuntimeBridgePlugin

class DMusicApplication : Application() {
    override fun onCreate() {
        super.onCreate()
        DMusicRuntimeBridgePlugin.delegateFactory = { context, messenger ->
            DMusicEngineBridge(context, messenger)
        }
    }
}
