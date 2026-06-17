package com.example.netoutpost

import android.content.Intent
import android.os.Build
import androidx.annotation.NonNull
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel

class MainActivity: FlutterActivity() {
    private val CHANNEL = "com.example.netoutpost/sync"

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
    }
}
