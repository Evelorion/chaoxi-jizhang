package com.aline.jier.jier

import android.content.Context
import org.json.JSONArray
import org.json.JSONObject

object AutoCaptureStore {
    private const val PREFS_NAME = "jier_auto_capture"
    private const val KEY_QUEUE = "pending_records"
    private const val MAX_RECORDS = 60

    fun upsert(context: Context, capture: LedgerCapture) {
        synchronized(this) {
            val queue = readQueue(context)
                .filterNot { it.id == capture.id }
                .toMutableList()
            queue += capture
            val trimmed = queue.takeLast(MAX_RECORDS)
            saveQueue(context, trimmed)
        }
    }

    fun enqueue(context: Context, capture: LedgerCapture) {
        upsert(context, capture)
    }

    fun drain(context: Context): List<LedgerCapture> {
        synchronized(this) {
            val queue = readQueue(context)
            saveQueue(context, emptyList())
            return queue
        }
    }

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
