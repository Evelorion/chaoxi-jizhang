package com.aline.jier.jier

import android.app.DownloadManager
import android.content.Context
import android.net.Uri
import android.os.Environment
import android.os.Handler
import android.os.HandlerThread
import java.io.File
import kotlin.math.min

/**
 * 模型下载交给安卓系统下载服务：退出应用、锁屏都会继续下。
 * 失败时会自动重试，并会在下载地址本身有问题时换成备用地址。
 */
class LocalModelDownloadBridge(private val context: Context) {
    private val manager =
        context.getSystemService(Context.DOWNLOAD_SERVICE) as DownloadManager
    private val preferences =
        context.getSharedPreferences("local_model_downloads", Context.MODE_PRIVATE)
    private val worker = HandlerThread("local-model-download").apply { start() }
    private val handler = Handler(worker.looper)

    private companion object {
        const val MAX_ATTEMPTS = 3
        val RETRY_DELAYS_MS = longArrayOf(5_000L, 20_000L, 60_000L)
        val ALLOWED_HOSTS = setOf("huggingface.co", "hf-mirror.com")
    }

    private fun validateModelId(modelId: String) {
        require(modelId.matches(Regex("[a-z0-9-]{1,48}"))) { "模型编号无效" }
    }

    private fun validateUrl(url: String) {
        val uri = Uri.parse(url)
        require(uri.scheme == "https" && uri.host in ALLOWED_HOSTS) {
            "模型下载地址无效"
        }
        require(uri.path?.endsWith(".gguf") == true) { "模型文件格式无效" }
    }

    private fun pendingFile(modelId: String): File {
        validateModelId(modelId)
        val directory = context.getExternalFilesDir(Environment.DIRECTORY_DOWNLOADS)
            ?: error("手机存储空间不可用")
        return File(directory, "$modelId.gguf.partial")
    }

    private fun jobId(modelId: String): Long = preferences.getLong("job_$modelId", -1L)

    private fun attempts(modelId: String): Int = preferences.getInt("attempts_$modelId", 0)

    @Synchronized
    fun start(
        modelId: String,
        url: String,
        alternateUrl: String?,
        title: String,
    ): Map<String, Any?> {
        validateModelId(modelId)
        validateUrl(url)
        val current = query(modelId)
        if (current["state"] in setOf("pending", "running", "paused", "successful")) {
            return current
        }
        cancel(modelId)
        preferences.edit()
            .putString("url_$modelId", url)
            .putString("alt_$modelId", alternateUrl?.takeIf { it != url } ?: "")
            .putString("title_$modelId", title.take(64))
            .putInt("attempts_$modelId", 0)
            .putLong("retryAt_$modelId", 0L)
            .putBoolean("done_$modelId", false)
            .apply()
        enqueue(modelId, url)
        return query(modelId)
    }

    @Synchronized
    fun query(modelId: String): Map<String, Any?> {
        validateModelId(modelId)
        val retries = attempts(modelId)
        val id = jobId(modelId)
        if (id < 0) {
            return idleMap(retries)
        }
        manager.query(DownloadManager.Query().setFilterById(id)).use { cursor ->
            if (!cursor.moveToFirst()) {
                preferences.edit().remove("job_$modelId").apply()
                return idleMap(retries)
            }
            val status = cursor.getInt(
                cursor.getColumnIndexOrThrow(DownloadManager.COLUMN_STATUS)
            )
            val reason = cursor.getInt(
                cursor.getColumnIndexOrThrow(DownloadManager.COLUMN_REASON)
            )
            val state = when (status) {
                DownloadManager.STATUS_PENDING -> "pending"
                DownloadManager.STATUS_RUNNING -> "running"
                DownloadManager.STATUS_PAUSED -> "paused"
                DownloadManager.STATUS_SUCCESSFUL -> "successful"
                DownloadManager.STATUS_FAILED -> "failed"
                else -> "idle"
            }
            var retryInSeconds = 0
            if (state == "successful") {
                preferences.edit()
                    .putBoolean("done_$modelId", true)
                    .putLong("retryAt_$modelId", 0L)
                    .apply()
            } else if (state == "failed" && !preferences.getBoolean("done_$modelId", false)) {
                val retryAt = scheduleRetry(modelId, reason)
                if (retryAt > 0) {
                    retryInSeconds =
                        ((retryAt - System.currentTimeMillis()) / 1000L).toInt().coerceAtLeast(0)
                }
            }
            return mapOf(
                "state" to state,
                "received" to cursor.getLong(
                    cursor.getColumnIndexOrThrow(DownloadManager.COLUMN_BYTES_DOWNLOADED_SO_FAR)
                ),
                "total" to cursor.getLong(
                    cursor.getColumnIndexOrThrow(DownloadManager.COLUMN_TOTAL_SIZE_BYTES)
                ),
                "reason" to reason,
                "attempts" to attempts(modelId),
                "maxAttempts" to MAX_ATTEMPTS,
                "retryInSeconds" to retryInSeconds,
            )
        }
    }

    @Synchronized
    fun cancel(modelId: String) {
        validateModelId(modelId)
        val id = jobId(modelId)
        if (id >= 0) {
            runCatching { manager.remove(id) }
        }
        preferences.edit()
            .remove("job_$modelId")
            .remove("attempts_$modelId")
            .remove("retryAt_$modelId")
            .remove("url_$modelId")
            .remove("alt_$modelId")
            .remove("title_$modelId")
            .remove("done_$modelId")
            .apply()
        val file = pendingFile(modelId)
        if (file.exists()) file.delete()
    }

    private fun idleMap(retries: Int): Map<String, Any?> = mapOf(
        "state" to "idle",
        "received" to 0L,
        "total" to 0L,
        "reason" to 0,
        "attempts" to retries,
        "maxAttempts" to MAX_ATTEMPTS,
        "retryInSeconds" to 0,
    )

    /** 安排一次自动重试，返回计划重试的时间点（0 表示不再重试）。 */
    private fun scheduleRetry(modelId: String, reason: Int): Long {
        val retries = attempts(modelId)
        if (retries >= MAX_ATTEMPTS) return 0L
        val now = System.currentTimeMillis()
        val planned = preferences.getLong("retryAt_$modelId", 0L)
        if (planned > now) return planned
        val delay = RETRY_DELAYS_MS[min(retries, RETRY_DELAYS_MS.size - 1)]
        val retryAt = now + delay
        preferences.edit()
            .putLong("retryAt_$modelId", retryAt)
            .putInt("lastReason_$modelId", reason)
            .apply()
        handler.postDelayed({ runCatching { performRetry(modelId) } }, delay)
        return retryAt
    }

    private fun performRetry(modelId: String) {
        synchronized(this) {
            preferences.edit().putLong("retryAt_$modelId", 0L).apply()
            val retries = attempts(modelId) + 1
            preferences.edit().putInt("attempts_$modelId", retries).apply()
            if (query(modelId)["state"] != "failed") return

            val reason = preferences.getInt("lastReason_$modelId", 0)
            val url = preferences.getString("url_$modelId", null) ?: return
            val alternate = preferences.getString("alt_$modelId", null).orEmpty()
            // 地址本身有问题时换备用地址；重试到最后一次也换一次试试。
            val sourceLooksBroken = reason == 1002 || reason in 400..599
            val nextUrl = when {
                alternate.isEmpty() -> url
                sourceLooksBroken || retries >= MAX_ATTEMPTS - 1 -> alternate
                else -> url
            }

            val old = jobId(modelId)
            if (old >= 0) runCatching { manager.remove(old) }
            val file = pendingFile(modelId)
            if (file.exists()) file.delete()
            enqueue(modelId, nextUrl)
        }
    }

    private fun enqueue(modelId: String, url: String) {
        val title = preferences.getString("title_$modelId", null) ?: "千问模型"
        val file = pendingFile(modelId)
        val request = DownloadManager.Request(Uri.parse(url))
            .setTitle(title)
            .setDescription("正在后台下载离线千问模型")
            .setMimeType("application/octet-stream")
            .setAllowedOverMetered(true)
            .setAllowedOverRoaming(false)
            .setNotificationVisibility(
                DownloadManager.Request.VISIBILITY_VISIBLE_NOTIFY_COMPLETED
            )
            .setDestinationInExternalFilesDir(
                context,
                Environment.DIRECTORY_DOWNLOADS,
                file.name,
            )
        val id = manager.enqueue(request)
        preferences.edit().putLong("job_$modelId", id).apply()
    }
}
