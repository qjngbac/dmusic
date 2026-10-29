package com.dmusic.runtimebridge

import android.content.Context
import io.flutter.embedding.engine.plugins.FlutterPlugin
import io.flutter.embedding.engine.plugins.activity.ActivityAware
import io.flutter.embedding.engine.plugins.activity.ActivityPluginBinding
import io.flutter.plugin.common.BinaryMessenger

class DMusicRuntimeBridgePlugin : FlutterPlugin, ActivityAware {
    companion object {
        @JvmStatic
        var delegateFactory: ((Context, BinaryMessenger) -> DMusicRuntimeDelegate)? = null
    }

    private var delegate: DMusicRuntimeDelegate? = null

    override fun onAttachedToEngine(binding: FlutterPlugin.FlutterPluginBinding) {
        val factory = checkNotNull(delegateFactory) {
            "MainApplication must install DMusicRuntimeBridgePlugin.delegateFactory before creating a Flutter engine."
        }
        delegate = factory(binding.applicationContext, binding.binaryMessenger)
    }

    override fun onAttachedToActivity(binding: ActivityPluginBinding) {
        delegate?.onActivityAttached(binding.activity)
    }

    override fun onReattachedToActivityForConfigChanges(binding: ActivityPluginBinding) {
        delegate?.onActivityAttached(binding.activity)
    }

    override fun onDetachedFromActivityForConfigChanges() {
        delegate?.onActivityDetached()
    }

    override fun onDetachedFromActivity() {
        delegate?.onActivityDetached()
    }

    override fun onDetachedFromEngine(binding: FlutterPlugin.FlutterPluginBinding) {
        val detachedDelegate = delegate
        delegate = null
        detachedDelegate?.onEngineDetached()
    }
}
