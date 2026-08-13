package com.nulleigenvalue.null_eigenvalue

import android.Manifest
import android.content.pm.PackageManager
import android.os.Build
import android.os.Bundle
import com.ryanheise.audioservice.AudioServiceActivity

// AudioServiceActivity rather than FlutterActivity: it is what binds the
// activity to the media session's Flutter engine, so a notification or a
// headphone button that arrives while the activity is gone still reaches the
// same isolate the UI is using.
class MainActivity : AudioServiceActivity() {

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        requestNotificationPermission()
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
}
