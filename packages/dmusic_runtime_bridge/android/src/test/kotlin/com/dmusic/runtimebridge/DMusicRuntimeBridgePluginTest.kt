package com.dmusic.runtimebridge

import android.app.Activity
import android.content.Context
import io.flutter.embedding.engine.plugins.FlutterPlugin.FlutterPluginBinding
import io.flutter.embedding.engine.plugins.activity.ActivityPluginBinding
import io.flutter.plugin.common.BinaryMessenger
import java.lang.reflect.Proxy
import org.junit.After
import org.junit.Assert.assertEquals
import org.junit.Assert.assertSame
import org.junit.Assert.assertThrows
import org.junit.Assert.assertTrue
import org.junit.Test

class DMusicRuntimeBridgePluginTest {
    @After
    fun clearFactory() {
        DMusicRuntimeBridgePlugin.delegateFactory = null
    }

    @Test
    fun missingApplicationFactoryFailsBeforeEngineAttachment() {
        val failure = assertThrows(IllegalStateException::class.java) {
            DMusicRuntimeBridgePlugin().onAttachedToEngine(engineBinding())
        }
        assertTrue(failure.message.orEmpty().contains("MainApplication"))
    }

    @Test
    fun engineAttachmentPassesItsContextAndMessengerToFactory() {
        val binding = engineBinding()
        val delegate = RecordingDelegate()
        DMusicRuntimeBridgePlugin.delegateFactory = { context, messenger ->
            assertSame(binding.applicationContext, context)
            assertSame(binding.binaryMessenger, messenger)
            delegate
        }

        val plugin = DMusicRuntimeBridgePlugin()
        plugin.onAttachedToEngine(binding)
        assertEquals(emptyList<String>(), delegate.events)
        plugin.onDetachedFromEngine(binding)
        assertEquals(listOf("engineDetached"), delegate.events)
    }

    @Test
    fun activityRecreationAndRemovalKeepEngineDelegateAlive() {
        val delegate = RecordingDelegate()
        DMusicRuntimeBridgePlugin.delegateFactory = { _, _ -> delegate }
        val plugin = DMusicRuntimeBridgePlugin()
        val engine = engineBinding()
        plugin.onAttachedToEngine(engine)
        val first = activityBinding()
        val second = activityBinding()

        plugin.onAttachedToActivity(first)
        plugin.onDetachedFromActivityForConfigChanges()
        plugin.onReattachedToActivityForConfigChanges(second)
        plugin.onDetachedFromActivity()

        assertEquals(listOf("activityAttached", "activityDetached", "activityAttached", "activityDetached"), delegate.events)
        assertEquals(listOf(first.activity, second.activity), delegate.activities)
        plugin.onDetachedFromEngine(engine)
        assertEquals("engineDetached", delegate.events.last())

        plugin.onDetachedFromActivity()
        plugin.onDetachedFromEngine(engine)
        assertEquals(5, delegate.events.size)
    }

    private class RecordingDelegate : DMusicRuntimeDelegate {
        val events = mutableListOf<String>()
        val activities = mutableListOf<Activity>()

        override fun onActivityAttached(activity: Activity) {
            events += "activityAttached"
            activities += activity
        }

        override fun onActivityDetached() {
            events += "activityDetached"
        }

        override fun onEngineDetached() {
            events += "engineDetached"
        }
    }

    private fun engineBinding(): FlutterPluginBinding {
        val messenger = interfaceProxy(BinaryMessenger::class.java) { null }
        // Android framework instances are identity tokens here; no platform methods run.
        val context = allocateWithoutConstructor(Activity::class.java) as Context
        return FlutterPluginBinding::class.java.constructors.single()
            .newInstance(context, null, messenger, null, null, null, null) as FlutterPluginBinding
    }

    private fun activityBinding(): ActivityPluginBinding {
        val activity = allocateWithoutConstructor(Activity::class.java)
        return interfaceProxy(ActivityPluginBinding::class.java) { name ->
            check(name == "getActivity") { "Unexpected Activity binding call: $name" }
            activity
        }
    }

    private fun <T : Any> interfaceProxy(type: Class<T>, invoke: (String) -> Any?): T =
        requireNotNull(type.cast(Proxy.newProxyInstance(type.classLoader, arrayOf(type)) { _, method, _ -> invoke(method.name) }))

    private fun <T : Any> allocateWithoutConstructor(type: Class<T>): T {
        // Android's compile classpath excludes JDK internals; this JVM-only test
        // obtains inert framework identity tokens without invoking their stubs.
        val unsafeClass = Class.forName("sun.misc.Unsafe")
        val field = unsafeClass.getDeclaredField("theUnsafe")
        field.isAccessible = true
        return requireNotNull(type.cast(unsafeClass.getMethod("allocateInstance", Class::class.java)
            .invoke(field.get(null), type)))
    }
}
