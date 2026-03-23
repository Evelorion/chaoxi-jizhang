package com.aline.jier.jier

import android.content.ComponentName
import android.content.Intent
import android.content.SharedPreferences
import android.os.Bundle
import android.provider.Settings
import android.view.WindowManager
import io.flutter.embedding.android.FlutterFragmentActivity
import io.flutter.embedding.android.RenderMode
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel

class MainActivity : FlutterFragmentActivity() {
    private val vaultCipher by lazy { VaultCipher() }
    private val privacyPrefs: SharedPreferences by lazy {
        getSharedPreferences(PRIVACY_PREFS, MODE_PRIVATE)
    }

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        window.setSoftInputMode(WindowManager.LayoutParams.SOFT_INPUT_ADJUST_NOTHING)
        applyScreenCaptureAllowed(loadScreenCaptureAllowed())
    }

    override fun getRenderMode(): RenderMode {
        return RenderMode.texture
    }

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)

        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, VAULT_CRYPTO_CHANNEL)
            .setMethodCallHandler(::handleCrypto)

        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, AUTO_CAPTURE_CHANNEL)
            .setMethodCallHandler(::handleAutoCapture)

        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, WINDOW_PRIVACY_CHANNEL)
            .setMethodCallHandler(::handleWindowPrivacy)
    }

    private fun handleCrypto(call: MethodCall, result: MethodChannel.Result) {
        val payload = call.argument<String>("payload")
        val passphrase = call.argument<String>("passphrase")
        if (payload.isNullOrBlank() || passphrase.isNullOrBlank()) {
            result.error("invalid_args", "payload 或 passphrase 为空。", null)
            return
        }

        runCatching {
            when (call.method) {
                "encryptLedger" -> vaultCipher.encrypt(payload, passphrase)
                "decryptLedger" -> vaultCipher.decrypt(payload, passphrase)
                else -> throw IllegalArgumentException("未支持的方法：${call.method}")
            }
        }.onSuccess(result::success).onFailure {
            result.error("crypto_failed", it.message ?: "加密通道失败。", null)
        }
    }

    private fun handleAutoCapture(call: MethodCall, result: MethodChannel.Result) {
        when (call.method) {
            "isNotificationAccessEnabled" -> result.success(isNotificationListenerEnabled())
            "openNotificationAccessSettings" -> {
                startActivity(Intent(Settings.ACTION_NOTIFICATION_LISTENER_SETTINGS))
                result.success(null)
            }
            "fetchPendingAutoRecords" -> {
                result.success(AutoCaptureStore.drain(applicationContext).map { it.toMap() })
            }
            else -> result.notImplemented()
        }
    }

    private fun handleWindowPrivacy(call: MethodCall, result: MethodChannel.Result) {
        when (call.method) {
            "setScreenCaptureAllowed" -> {
                val allowed = call.argument<Boolean>("allowed") ?: false
                val persist = call.argument<Boolean>("persist") ?: true
                runOnUiThread {
                    if (persist) {
                        persistScreenCaptureAllowed(allowed)
                    }
                    applyScreenCaptureAllowed(allowed)
                }
                result.success(null)
            }
            "isScreenCaptureAllowed" -> result.success(loadScreenCaptureAllowed())
            else -> result.notImplemented()
        }
    }

    private fun loadScreenCaptureAllowed(): Boolean {
        return privacyPrefs.getBoolean(KEY_ALLOW_SCREENSHOTS, true)
    }

    private fun persistScreenCaptureAllowed(allowed: Boolean) {
        privacyPrefs.edit().putBoolean(KEY_ALLOW_SCREENSHOTS, allowed).apply()
    }

    private fun applyScreenCaptureAllowed(allowed: Boolean) {
        if (allowed) {
            window.clearFlags(WindowManager.LayoutParams.FLAG_SECURE)
        } else {
            window.addFlags(WindowManager.LayoutParams.FLAG_SECURE)
        }
    }

    private fun isNotificationListenerEnabled(): Boolean {
        val enabledListeners = Settings.Secure.getString(
            contentResolver,
            "enabled_notification_listeners"
        ) ?: return false
        val expected = ComponentName(
            this,
            LedgerNotificationListenerService::class.java
        ).flattenToString()
        return enabledListeners.split(':').any { it.equals(expected, ignoreCase = true) }
    }

    private companion object {
        const val VAULT_CRYPTO_CHANNEL = "com.aline.jier/vault_crypto"
        const val AUTO_CAPTURE_CHANNEL = "com.aline.jier/auto_capture"
        const val WINDOW_PRIVACY_CHANNEL = "com.aline.jier/window_privacy"
        const val PRIVACY_PREFS = "jier_window_privacy"
        const val KEY_ALLOW_SCREENSHOTS = "allow_screenshots"
    }
}
