package com.aline.jier.jier

import android.content.Context
import org.json.JSONArray

object NotificationCorrelationStore {
    private const val PREFS_NAME = "jier_notification_correlation"
    private const val KEY_RECENT_CAPTURES = "recent_captures"
    private const val KEY_PENDING_EVENTS = "pending_events"
    private const val MAX_RECENT_CAPTURES = 80
    private const val MAX_PENDING_EVENTS = 80
    private const val RECENT_TTL_MS = 3 * 60 * 60 * 1000L
    private const val PENDING_TTL_MS = 90 * 60 * 1000L

    fun findMatchingCapture(context: Context, event: NotificationEvent): LedgerCapture? {
        val recent = readRecentCaptures(context)
        val matches = recent.filter { CaptureLinking.matchesCapture(it, event) }
        if (event.amount == null && CaptureLinking.isShoppingSource(event.source)) {
            return matches.singleOrNull()
        }
        return matches.lastOrNull()
    }

    fun upsertRecentCapture(context: Context, capture: LedgerCapture) {
        synchronized(this) {
            val recent = pruneRecent(readRecentCaptures(context))
                .filterNot { it.id == capture.id }
                .toMutableList()
            recent += capture
            saveRecentCaptures(context, recent.takeLast(MAX_RECENT_CAPTURES))
        }
    }

    fun enqueuePendingEvent(context: Context, event: NotificationEvent) {
        synchronized(this) {
            val pending = prunePending(readPendingEvents(context))
                .filterNot {
                    it.profileId == event.profileId &&
                        it.postedAtMillis == event.postedAtMillis &&
                        it.source == event.source &&
                        it.mergeKey == event.mergeKey
                }
                .toMutableList()
            pending += event
            savePendingEvents(context, pending.takeLast(MAX_PENDING_EVENTS))
        }
    }

    fun consumeMatchingPendingEvents(context: Context, capture: LedgerCapture): List<NotificationEvent> {
        synchronized(this) {
            val recentCaptures = pruneRecent(readRecentCaptures(context)) + capture
            val pending = prunePending(readPendingEvents(context)).toMutableList()
            val matched = pending.filter { event ->
                if (!CaptureLinking.matchesCapture(capture, event)) {
                    return@filter false
                }
                if (event.amount == null && CaptureLinking.isShoppingSource(event.source)) {
                    val candidateCount = recentCaptures.count {
                        CaptureLinking.matchesCapture(it, event)
                    }
                    return@filter candidateCount == 1
                }
                true
            }
            if (matched.isNotEmpty()) {
                pending.removeAll(matched.toSet())
                savePendingEvents(context, pending)
            }
            return matched.sortedBy { it.postedAtMillis }
        }
    }

    private fun readRecentCaptures(context: Context): List<LedgerCapture> {
        val prefs = context.getSharedPreferences(PREFS_NAME, Context.MODE_PRIVATE)
        val raw = prefs.getString(KEY_RECENT_CAPTURES, "[]") ?: "[]"
        val jsonArray = runCatching { JSONArray(raw) }.getOrElse { JSONArray() }
        return buildList {
            for (index in 0 until jsonArray.length()) {
                val json = jsonArray.optJSONObject(index) ?: continue
                add(LedgerCapture.fromJson(json))
            }
        }
    }

    private fun saveRecentCaptures(context: Context, captures: List<LedgerCapture>) {
        val prefs = context.getSharedPreferences(PREFS_NAME, Context.MODE_PRIVATE)
        val jsonArray = JSONArray()
        captures.forEach { jsonArray.put(it.toJson()) }
        prefs.edit().putString(KEY_RECENT_CAPTURES, jsonArray.toString()).apply()
    }

    private fun pruneRecent(captures: List<LedgerCapture>): List<LedgerCapture> {
        val cutoff = System.currentTimeMillis() - RECENT_TTL_MS
        return captures.filter { it.postedAtMillis >= cutoff }
    }

    private fun readPendingEvents(context: Context): List<NotificationEvent> {
        val prefs = context.getSharedPreferences(PREFS_NAME, Context.MODE_PRIVATE)
        val raw = prefs.getString(KEY_PENDING_EVENTS, "[]") ?: "[]"
        val jsonArray = runCatching { JSONArray(raw) }.getOrElse { JSONArray() }
        return buildList {
            for (index in 0 until jsonArray.length()) {
                val json = jsonArray.optJSONObject(index) ?: continue
                add(NotificationEvent.fromJson(json))
            }
        }
    }

    private fun savePendingEvents(context: Context, events: List<NotificationEvent>) {
        val prefs = context.getSharedPreferences(PREFS_NAME, Context.MODE_PRIVATE)
        val jsonArray = JSONArray()
        events.forEach { jsonArray.put(it.toJson()) }
        prefs.edit().putString(KEY_PENDING_EVENTS, jsonArray.toString()).apply()
    }

    private fun prunePending(events: List<NotificationEvent>): List<NotificationEvent> {
        val cutoff = System.currentTimeMillis() - PENDING_TTL_MS
        return events.filter { it.postedAtMillis >= cutoff }
    }
}
