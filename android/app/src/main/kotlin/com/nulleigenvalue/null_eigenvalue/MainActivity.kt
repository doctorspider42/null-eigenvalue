package com.nulleigenvalue.null_eigenvalue

import android.Manifest
import android.content.pm.ActivityInfo
import android.content.pm.PackageManager
import android.os.Build
import android.os.Bundle
import com.ryanheise.audioservice.AudioServiceActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel

// AudioServiceActivity rather than FlutterActivity: it is what binds the
// activity to the media session's Flutter engine, so a notification or a
// headphone button that arrives while the activity is gone still reaches the
// same isolate the UI is using.
class MainActivity : AudioServiceActivity() {

    // One APK serves a handset and a television, so everything that differs
    // between them is decided here rather than in the manifest - which cannot
    // say "portrait on a phone, landscape on a set".
    private val isTelevision: Boolean
        get() = packageManager.hasSystemFeature(PackageManager.FEATURE_LEANBACK)

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)

        requestedOrientation = if (isTelevision) {
            ActivityInfo.SCREEN_ORIENTATION_LANDSCAPE
        } else {
            ActivityInfo.SCREEN_ORIENTATION_PORTRAIT
        }

        // Not on a television. There the grant buys a transport in a
        // notification shade nobody opens, and it costs a permission dialog
        // that has to be dismissed with a remote before anything is heard.
        if (!isTelevision) {
            requestNotificationPermission()
        }
    }

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        // Dart decides the entire input story from this one answer and needs it
        // before the first frame. Cheaper than it looks: startup already awaits
        // the engine and the textures.
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, DEVICE_CHANNEL)
            .setMethodCallHandler { call, result ->
                when (call.method) {
                    "isTelevision" -> result.success(isTelevision)
                    else -> result.notImplemented()
                }
            }
    }

    // Android 13 made notifications opt-in, and audio_service does not ask.
    // Without the grant the foreground service still runs and the drone still
    // plays with the screen off - but the transport never appears in the
    // shade or on the lock screen, which is most of the point. Asked for here,
    // in ten lines of Kotlin, rather than by taking on a permissions plugin
    // for a single string.
    private fun requestNotificationPermission() {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.TIRAMISU) return
        val granted = checkSelfPermission(Manifest.permission.POST_NOTIFICATIONS) ==
            PackageManager.PERMISSION_GRANTED
        // Deliberately fire-and-forget: a refusal costs the notification, not
        // the audio, so there is nothing useful to do with the answer.
        if (!granted) {
            requestPermissions(arrayOf(Manifest.permission.POST_NOTIFICATIONS), 4242)
        }
    }

    private companion object {
        const val DEVICE_CHANNEL = "nulleigenvalue/device"
    }
}
