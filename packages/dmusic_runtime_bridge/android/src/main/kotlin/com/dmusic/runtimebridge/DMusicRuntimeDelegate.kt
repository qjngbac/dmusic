package com.dmusic.runtimebridge

import android.app.Activity

interface DMusicRuntimeDelegate {
    fun onActivityAttached(activity: Activity)
    fun onActivityDetached()
    fun onEngineDetached()
}
