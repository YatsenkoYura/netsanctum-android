package com.example.netoutpost

import android.content.Intent
import android.os.Build
import android.security.keystore.KeyGenParameterSpec
import android.security.keystore.KeyProperties
import android.util.Base64
import androidx.annotation.NonNull
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel
import java.security.KeyStore
import javax.crypto.Cipher
import javax.crypto.KeyGenerator
import javax.crypto.SecretKey
import javax.crypto.spec.GCMParameterSpec

class MainActivity: FlutterActivity() {
    private val CHANNEL = "com.example.netoutpost/sync"
    private val CREDENTIALS_CHANNEL = "com.example.netoutpost/credentials"
    private val KEY_ALIAS = "netoutpost_master_key"
    private val CREDENTIAL_VALUE = "master_api_key"

    override fun configureFlutterEngine(@NonNull flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, CHANNEL).setMethodCallHandler { call, result ->
            when (call.method) {
                "startService" -> {
                    val title = call.argument<String>("title") ?: "Syncing..."
                    val intent = Intent(this, OutpostSyncService::class.java).apply {
                        action = OutpostSyncService.ACTION_START
                        putExtra(OutpostSyncService.EXTRA_TITLE, title)
                    }
                    if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
                        startForegroundService(intent)
                    } else {
                        startService(intent)
                    }
                    result.success(null)
                }
                "updateProgress" -> {
                    val title = call.argument<String>("title")
                    val progress = call.argument<Int>("progress") ?: 0
                    val speed = call.argument<String>("speed") ?: ""
                    val remaining = call.argument<String>("remaining") ?: ""
                    
                    val intent = Intent(this, OutpostSyncService::class.java).apply {
                        action = OutpostSyncService.ACTION_UPDATE
                        putExtra(OutpostSyncService.EXTRA_TITLE, title)
                        putExtra(OutpostSyncService.EXTRA_PROGRESS, progress)
                        putExtra(OutpostSyncService.EXTRA_SPEED, speed)
                        putExtra(OutpostSyncService.EXTRA_REMAINING, remaining)
                    }
                    startService(intent)
                    result.success(null)
                }
                "stopService" -> {
                    val intent = Intent(this, OutpostSyncService::class.java).apply {
                        action = OutpostSyncService.ACTION_STOP
                    }
                    startService(intent)
                    result.success(null)
                }
                else -> {
                    result.notImplemented()
                }
            }
        }

        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, CREDENTIALS_CHANNEL).setMethodCallHandler { call, result ->
            try {
                when (call.method) {
                    "read" -> result.success(readCredential())
                    "write" -> {
                        writeCredential(call.arguments as String)
                        result.success(null)
                    }
                    "delete" -> {
                        getSharedPreferences("netoutpost_credentials", MODE_PRIVATE)
                            .edit().remove(CREDENTIAL_VALUE).apply()
                        result.success(null)
                    }
                    else -> result.notImplemented()
                }
            } catch (error: Exception) {
                result.error("credential_storage", error.message, null)
            }
        }
    }

    private fun getCredentialKey(): SecretKey {
        val keyStore = KeyStore.getInstance("AndroidKeyStore").apply { load(null) }
        val existingKey = keyStore.getKey(KEY_ALIAS, null) as? SecretKey
        if (existingKey != null) return existingKey

        val generator = KeyGenerator.getInstance(KeyProperties.KEY_ALGORITHM_AES, "AndroidKeyStore")
        generator.init(
            KeyGenParameterSpec.Builder(
                KEY_ALIAS,
                KeyProperties.PURPOSE_ENCRYPT or KeyProperties.PURPOSE_DECRYPT,
            )
                .setBlockModes(KeyProperties.BLOCK_MODE_GCM)
                .setEncryptionPaddings(KeyProperties.ENCRYPTION_PADDING_NONE)
                .build()
        )
        return generator.generateKey()
    }

    private fun writeCredential(value: String) {
        val cipher = Cipher.getInstance("AES/GCM/NoPadding")
        cipher.init(Cipher.ENCRYPT_MODE, getCredentialKey())
        val encrypted = cipher.doFinal(value.toByteArray(Charsets.UTF_8))
        val payload = cipher.iv + encrypted
        getSharedPreferences("netoutpost_credentials", MODE_PRIVATE)
            .edit().putString(CREDENTIAL_VALUE, Base64.encodeToString(payload, Base64.NO_WRAP)).apply()
    }

    private fun readCredential(): String? {
        val encoded = getSharedPreferences("netoutpost_credentials", MODE_PRIVATE)
            .getString(CREDENTIAL_VALUE, null) ?: return null
        val payload = Base64.decode(encoded, Base64.NO_WRAP)
        if (payload.size <= 12) error("Invalid encrypted credential")

        val cipher = Cipher.getInstance("AES/GCM/NoPadding")
        cipher.init(Cipher.DECRYPT_MODE, getCredentialKey(), GCMParameterSpec(128, payload.copyOfRange(0, 12)))
        return String(cipher.doFinal(payload.copyOfRange(12, payload.size)), Charsets.UTF_8)
    }
}
