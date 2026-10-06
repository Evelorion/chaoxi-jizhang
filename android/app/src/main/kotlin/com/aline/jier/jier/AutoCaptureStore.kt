package com.aline.jier.jier

import android.content.Context
import org.json.JSONArray

/**
 * 待处理队列：解析成功但还没写进账本的通知记录。
 * 通知监听线程只做入队，处理交给应用（AI 顺序处理），互不阻塞。
 */
object AutoCaptureStore {
    private const val PREFS_NAME = "jier_auto_capture"
    private const val KEY_QUEUE = "pending_records"
    private const val KEY_DROPPED_TOTAL = "pending_dropped_total"

    /** 队列上限。超出时丢最旧的，并记下丢了多少条，界面上会说清楚。 */
    private const val MAX_RECORDS = 120

    fun upsert(context: Context, capture: LedgerCapture) {
        synchronized(this) {
            val prefs = context.getSharedPreferences(PREFS_NAME, Context.MODE_PRIVATE)
            val queue = readQueue(context)
                .filterNot { it.id == capture.id }
                .toMutableList()
            queue += capture
            var dropped = prefs.getInt(KEY_DROPPED_TOTAL, 0)
            while (queue.size > MAX_RECORDS) {
                queue.removeAt(0)
                dropped += 1
            }
            saveQueue(context, queue)
            if (dropped != prefs.getInt(KEY_DROPPED_TOTAL, 0)) {
                prefs.edit().putInt(KEY_DROPPED_TOTAL, dropped).apply()
            }
        }
    }

    fun enqueue(context: Context, capture: LedgerCapture) {
        upsert(context, capture)
    }

    fun peek(context: Context): List<LedgerCapture> {
        synchronized(this) {
            return readQueue(context)
        }
    }

    fun pendingCount(context: Context): Int = synchronized(this) {
        readQueue(context).size
    }

    /**
     * 标记已完成：把已经写进账本的记录移出队列。
     * 只有确认写入成功才会调用，否则下一次同步会重来一次（写入本身按 id 幂等）。
     */
    fun acknowledge(context: Context, records: List<Map<String, Any?>>) {
        synchronized(this) {
            val queue = readQueue(context)
            val remaining = queue.filterNot { current ->
                records.any { snapshot ->
                    snapshot["id"] == current.id &&
                        snapshot["rawBody"] == current.rawBody &&
                        snapshot["detailSummary"] == current.detailSummary &&
                        (snapshot["amount"] as? Number)?.toDouble() == current.amount
                }
            }
            if (remaining.size != queue.size) saveQueue(context, remaining)
        }
    }

    fun droppedTotal(context: Context): Int =
        context.getSharedPreferences(PREFS_NAME, Context.MODE_PRIVATE)
            .getInt(KEY_DROPPED_TOTAL, 0)

    private fun readQueue(context: Context): MutableList<LedgerCapture> {
        val prefs = context.getSharedPreferences(PREFS_NAME, Context.MODE_PRIVATE)
        val raw = prefs.getString(KEY_QUEUE, "[]") ?: "[]"
        val jsonArray = runCatching { JSONArray(raw) }.getOrElse { JSONArray() }
        val list = mutableListOf<LedgerCapture>()
        for (index in 0 until jsonArray.length()) {
            val item = jsonArray.optJSONObject(index) ?: continue
            list += LedgerCapture.fromJson(item)
        }
        return list
    }

    private fun saveQueue(context: Context, records: List<LedgerCapture>) {
        val prefs = context.getSharedPreferences(PREFS_NAME, Context.MODE_PRIVATE)
        val jsonArray = JSONArray()
        records.forEach { jsonArray.put(it.toJson()) }
        prefs.edit().putString(KEY_QUEUE, jsonArray.toString()).apply()
    }
}
