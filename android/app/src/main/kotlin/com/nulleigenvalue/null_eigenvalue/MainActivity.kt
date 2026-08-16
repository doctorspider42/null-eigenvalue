package com.nulleigenvalue.null_eigenvalue

import android.Manifest
import android.content.Intent
import android.content.pm.ActivityInfo
import android.content.pm.PackageManager
import android.net.Uri
import android.os.Build
import android.os.Bundle
import android.provider.Settings
import androidx.core.content.FileProvider
import com.ryanheise.audioservice.AudioServiceActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel
import java.io.File

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

        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, INSTALLER_CHANNEL)
            .setMethodCallHandler { call, result ->
                when (call.method) {
                    // Where Dart should put the download. Asked for rather than
                    // assumed: the APK has to land under a root declared in
                    // update_paths.xml or FileProvider refuses to make a URI
                    // for it, and Dart's own temporary directory is not that
                    // place.
                    "stagingDir" -> {
                        val dir = File(cacheDir, "updates")
                        dir.mkdirs()
                        result.success(dir.absolutePath)
                    }
                    "install" -> {
                        val path = call.argument<String>("path")
                        result.success(
                            if (path == null) "no path given" else install(File(path))
                        )
                    }
                    else -> result.notImplemented()
                }
            }
    }

    // Hands a downloaded APK to the system installer.
    //
    // Returns null when the installer opened, or a short reason when it did
    // not. A reason rather than a bare false because this path has no console
    // behind it - it ends on a phone or a television, and "update failed" with
    // nothing after it is not something anyone can act on or report.
    //
    // The per-app install permission cannot be requested with a dialog; the
    // only route is the settings screen, so a refusal opens it rather than
    // returning a failure the user has no way to clear.
    private fun install(apk: File): String? {
        if (!apk.isFile) return "no file at ${apk.path}"

        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O &&
            !packageManager.canRequestPackageInstalls()
        ) {
            openUnknownSourcesSettings()
            return "allow unknown apps, then retry"
        }

        return try {
            // Inside the try, because getUriForFile throws when the file is not
            // under a root named in update_paths.xml, and that throw lands
            // after a download which has already finished.
            val uri: Uri = FileProvider.getUriForFile(
                this,
                "$packageName.updates",
                apk,
            )
            val intent = Intent(Intent.ACTION_VIEW).apply {
                setDataAndType(uri, "application/vnd.android.package-archive")
                addFlags(Intent.FLAG_GRANT_READ_URI_PERMISSION)
                addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
            }
            startActivity(intent)
            null
        } catch (e: Exception) {
            // The class name earns its place: "failed to find configured root"
            // and "no activity found to handle intent" are different repairs.
            "${e.javaClass.simpleName}: ${e.message?.take(90) ?: "no detail"}"
        }
    }

    private fun openUnknownSourcesSettings() {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.O) return
        try {
            startActivity(
                Intent(
                    Settings.ACTION_MANAGE_UNKNOWN_APP_SOURCES,
                    Uri.parse("package:$packageName"),
                ).addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
            )
        } catch (_: Exception) {
            // Some devices do not carry that settings screen. The reason above
            // still says what to allow; this was only a shortcut to it.
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
        const val INSTALLER_CHANNEL = "nulleigenvalue/installer"
    }
}
