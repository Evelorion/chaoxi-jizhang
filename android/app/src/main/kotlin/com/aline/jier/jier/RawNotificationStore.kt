package com.aline.jier.jier

import android.content.Context
import org.json.JSONArray
import org.json.JSONObject
import java.security.MessageDigest

/**
 * 一条原始通知。收到通知时先原样存下来，再交给解析和 AI，
 * 这样解析失败也不会丢，之后还能回看原文、重新处理。
 */
data class RawNotification(
    val id: String,
    val packageName: String,
    val sourceLabel: String,
    val title: String,
    val body: String,
    val profileId: Int,
    val postedAtMillis: Long,
    val capturedAtMillis: Long,
    /** parsed=已生成待处理记录；unparsed=看着像支付但没解析出来 */
    val status: String,
    val note: String,
) {
    fun toJson(): JSONObject = JSONObject().apply {
        put("id", id)
        put("packageName", packageName)
        put("sourceLabel", sourceLabel)
        put("title", title)
        put("body", body)
        put("profileId", profileId)
        put("postedAtMillis", postedAtMillis)
        put("capturedAtMillis", capturedAtMillis)
        put("status", status)
        put("note", note)
    }

    fun toMap(): Map<String, Any?> = mapOf(
        "id" to id,
        "packageName" to packageName,
        "sourceLabel" to sourceLabel,
        "title" to title,
        "body" to body,
        "profileId" to profileId,
        "postedAtMillis" to postedAtMillis,
        "capturedAtMillis" to capturedAtMillis,
        "status" to status,
        "note" to note,
    )

    companion object {
        fun fromJson(json: JSONObject): RawNotification = RawNotification(
            id = json.optString("id"),
            packageName = json.optString("packageName"),
            sourceLabel = json.optString("sourceLabel"),
            title = json.optString("title"),
            body = json.optString("body"),
            profileId = json.optInt("profileId"),
            postedAtMillis = json.optLong("postedAtMillis"),
            capturedAtMillis = json.optLong("capturedAtMillis"),
            status = json.optString("status", "unparsed"),
            note = json.optString("note"),
        )
    }
}

/**
 * 通知原文收件箱。只存“看起来像支付”的通知，微信聊天等无关内容不入库；
 * 只保存在应用私有目录里，最多保留最近 120 条。
 */
object RawNotificationStore {
    private const val PREFS_NAME = "jier_raw_notifications"
    private const val KEY_INBOX = "raw_inbox"
    private const val KEY_CAPTURED_TOTAL = "captured_total"
    private const val KEY_PARSED_TOTAL = "parsed_total"
    private const val KEY_DROPPED_TOTAL = "dropped_total"
    private const val MAX_RECORDS = 120

    private val packageLabels = mapOf(
        "com.tencent.mm" to "微信",
        "com.eg.android.AlipayGphone" to "支付宝",
        "com.google.android.apps.walletnfcrel" to "Google Pay",
        "com.google.android.apps.nbu.paisa.user" to "Google Pay",
        "com.taobao.taobao" to "淘宝",
        "com.jingdong.app.mall" to "京东",
        "com.xunmeng.pinduoduo" to "拼多多",
        "com.taobao.idlefish" to "闲鱼",
        "com.icbc" to "工商银行",
        "com.icbc.im" to "工商银行",
        "com.chinamworld.main" to "建设银行",
        "com.android.bankabc" to "农业银行",
        "com.chinamworld.bocmbci" to "中国银行",
        "com.bankcomm.Bankcomm" to "交通银行",
        "com.yitong.mbank.psbc" to "邮储银行",
    )

    fun labelFor(packageName: String): String =
        packageLabels[packageName] ?: packageName

    /** 收到通知时立刻调用，返回记录编号用于之后更新状态。 */
    fun append(
        context: Context,
        packageName: String,
        title: String,
        body: String,
        profileId: Int,
        postedAtMillis: Long,
    ): String {
        synchronized(this) {
            val prefs = context.getSharedPreferences(PREFS_NAME, Context.MODE_PRIVATE)
            val id = buildId(packageName, title, body, postedAtMillis)
            val queue = readInbox(prefs).toMutableList()
            queue.removeAll { it.id == id || (it.packageName == packageName && it.postedAtMillis == postedAtMillis) }
            queue += RawNotification(
                id = id,
                packageName = packageName,
                sourceLabel = labelFor(packageName),
                title = title.take(120),
                body = body.take(400),
                profileId = profileId,
                postedAtMillis = postedAtMillis,
                capturedAtMillis = System.currentTimeMillis(),
                status = "unparsed",
                note = "",
            )
            val capturedTotal = prefs.getInt(KEY_CAPTURED_TOTAL, 0) + 1
            var dropped = prefs.getInt(KEY_DROPPED_TOTAL, 0)
            while (queue.size > MAX_RECORDS) {
                queue.removeAt(0)
                dropped += 1
            }
            prefs.edit()
                .putString(KEY_INBOX, encode(queue))
                .putInt(KEY_CAPTURED_TOTAL, capturedTotal)
                .putInt(KEY_DROPPED_TOTAL, dropped)
                .apply()
            return id
        }
    }

    /** 解析完成后回填结果，方便在应用里核对“原文 → 记成了什么”。 */
    fun markStatus(
        context: Context,
        id: String,
        status: String,
        note: String,
    ) {
        if (id.isEmpty()) return
        synchronized(this) {
            val prefs = context.getSharedPreferences(PREFS_NAME, Context.MODE_PRIVATE)
            val queue = readInbox(prefs).toMutableList()
            val index = queue.indexOfFirst { it.id == id }
            if (index < 0) return
            queue[index] = queue[index].copy(status = status, note = note.take(80))
            var parsedTotal = prefs.getInt(KEY_PARSED_TOTAL, 0)
            if (status == "parsed") parsedTotal += 1
            prefs.edit()
                .putString(KEY_INBOX, encode(queue))
                .putInt(KEY_PARSED_TOTAL, parsedTotal)
                .apply()
        }
    }

    fun peek(context: Context, limit: Int): List<RawNotification> {
        synchronized(this) {
            val prefs = context.getSharedPreferences(PREFS_NAME, Context.MODE_PRIVATE)
            val inbox = readInbox(prefs)
            if (limit <= 0 || inbox.size <= limit) return inbox.reversed()
            return inbox.takeLast(limit).reversed()
        }
    }

    fun clear(context: Context) {
        synchronized(this) {
            context.getSharedPreferences(PREFS_NAME, Context.MODE_PRIVATE)
                .edit()
                .putString(KEY_INBOX, "[]")
                .apply()
        }
    }

    fun stats(context: Context): Map<String, Any?> {
        synchronized(this) {
            val prefs = context.getSharedPreferences(PREFS_NAME, Context.MODE_PRIVATE)
            val inbox = readInbox(prefs)
            return mapOf(
                "capturedTotal" to prefs.getInt(KEY_CAPTURED_TOTAL, 0),
                "parsedTotal" to prefs.getInt(KEY_PARSED_TOTAL, 0),
                "droppedTotal" to prefs.getInt(KEY_DROPPED_TOTAL, 0),
                "inboxCount" to inbox.size,
                "unparsedCount" to inbox.count { it.status != "parsed" },
            )
        }
    }

    private fun buildId(
        packageName: String,
        title: String,
        body: String,
        postedAtMillis: Long,
    ): String {
        val digest = MessageDigest.getInstance("SHA-256")
            .digest("$packageName|$title|$body|$postedAtMillis".toByteArray())
            .joinToString("") { "%02x".format(it) }
        return digest.take(24)
    }

    private fun readInbox(prefs: android.content.SharedPreferences): List<RawNotification> {
        val raw = prefs.getString(KEY_INBOX, "[]") ?: "[]"
        val array = runCatching { JSONArray(raw) }.getOrElse { JSONArray() }
        val list = mutableListOf<RawNotification>()
        for (index in 0 until array.length()) {
            val item = array.optJSONObject(index) ?: continue
            list += RawNotification.fromJson(item)
        }
        return list
    }

    private fun encode(records: List<RawNotification>): String {
        val array = JSONArray()
        records.forEach { array.put(it.toJson()) }
        return array.toString()
    }
}
