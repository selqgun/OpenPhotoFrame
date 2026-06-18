package io.github.micw.openphotoframe

import android.app.PendingIntent
import android.app.admin.DevicePolicyManager
import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import android.content.IntentFilter
import android.content.pm.PackageInstaller
import android.os.Build
import android.util.Log
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel
import java.io.File

/**
 * Handles app self-update via Flutter Method Channel (GitHub releases, opt-in).
 *
 * Uses [PackageInstaller], which covers both cases with a single code path:
 * - As Device Owner the install runs silently (no system dialog).
 * - Otherwise the system shows its install confirmation, which we launch from
 *   the STATUS_PENDING_USER_ACTION callback.
 */
class UpdaterHandler(private val context: Context) {
    companion object {
        private const val TAG = "UpdaterHandler"
        private const val CHANNEL = "io.github.micw.openphotoframe/updater"
        private const val INSTALL_ACTION = "io.github.micw.openphotoframe.INSTALL_STATUS"
    }

    private val devicePolicyManager: DevicePolicyManager by lazy {
        context.getSystemService(Context.DEVICE_POLICY_SERVICE) as DevicePolicyManager
    }

    private var statusReceiverRegistered = false

    fun configureChannel(flutterEngine: FlutterEngine) {
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, CHANNEL).setMethodCallHandler { call, result ->
            when (call.method) {
                "isDeviceOwner" -> result.success(isDeviceOwner())
                "getSupportedAbis" -> result.success(Build.SUPPORTED_ABIS.toList())
                "installApk" -> {
                    val path = call.argument<String>("path")
                    if (path == null) {
                        result.error("INVALID_ARGUMENT", "path is required", null)
                    } else {
                        installApk(path, result)
                    }
                }
                else -> result.notImplemented()
            }
        }
    }

    private fun isDeviceOwner(): Boolean {
        return try {
            devicePolicyManager.isDeviceOwnerApp(context.packageName)
        } catch (e: Exception) {
            Log.w(TAG, "isDeviceOwner check failed", e)
            false
        }
    }

    private fun installApk(apkPath: String, result: MethodChannel.Result) {
        try {
            val apk = File(apkPath)
            if (!apk.exists()) {
                result.error("FILE_NOT_FOUND", "APK not found: $apkPath", null)
                return
            }

            registerStatusReceiverOnce()

            val installer = context.packageManager.packageInstaller
            val params = PackageInstaller.SessionParams(
                PackageInstaller.SessionParams.MODE_FULL_INSTALL
            )
            val sessionId = installer.createSession(params)
            installer.openSession(sessionId).use { session ->
                session.openWrite("package", 0, apk.length()).use { out ->
                    apk.inputStream().use { input -> input.copyTo(out) }
                    session.fsync(out)
                }

                val intent = Intent(INSTALL_ACTION).setPackage(context.packageName)
                val flags = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.S) {
                    PendingIntent.FLAG_MUTABLE or PendingIntent.FLAG_UPDATE_CURRENT
                } else {
                    PendingIntent.FLAG_UPDATE_CURRENT
                }
                val pending = PendingIntent.getBroadcast(context, sessionId, intent, flags)
                session.commit(pending.intentSender)
            }

            Log.i(TAG, "Install session committed (deviceOwner=${isDeviceOwner()})")
            result.success(true)
        } catch (e: Exception) {
            Log.e(TAG, "installApk failed", e)
            result.error("INSTALL_FAILED", e.message, null)
        }
    }

    private fun registerStatusReceiverOnce() {
        if (statusReceiverRegistered) return
        statusReceiverRegistered = true

        val receiver = object : BroadcastReceiver() {
            override fun onReceive(c: Context, intent: Intent) {
                when (val status = intent.getIntExtra(PackageInstaller.EXTRA_STATUS, -999)) {
                    PackageInstaller.STATUS_PENDING_USER_ACTION -> {
                        @Suppress("DEPRECATION")
                        val confirm = intent.getParcelableExtra<Intent>(Intent.EXTRA_INTENT)
                        confirm?.addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
                        if (confirm != null) {
                            context.startActivity(confirm)
                        } else {
                            Log.w(TAG, "Pending user action but no confirm intent")
                        }
                    }
                    PackageInstaller.STATUS_SUCCESS -> Log.i(TAG, "Update installed successfully")
                    else -> Log.w(
                        TAG,
                        "Install status=$status msg=${intent.getStringExtra(PackageInstaller.EXTRA_STATUS_MESSAGE)}"
                    )
                }
            }
        }

        val filter = IntentFilter(INSTALL_ACTION)
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU) {
            context.registerReceiver(receiver, filter, Context.RECEIVER_NOT_EXPORTED)
        } else {
            @Suppress("UnspecifiedRegisterReceiverFlag")
            context.registerReceiver(receiver, filter)
        }
    }
}
