package com.aline.jier.jier

import org.json.JSONObject

data class NotificationEvent(
    val packageName: String,
    val source: String,
    val title: String,
    val merchant: String,
    val counterpartyName: String = "",
    val rawBody: String,
    val scenario: String,
    val detailSummary: String,
    val amount: Double?,
    val entryType: String,
    val channel: String,
    val capturedAt: String,
    val postedAtMillis: Long,
    val confidence: Double,
    val defaultCategoryId: String,
    val profileId: Int,
    val mergeKey: String,
    val eventKind: String,
) {
    fun toJson(): JSONObject = JSONObject().apply {
        put("packageName", packageName)
        put("source", source)
        put("title", title)
        put("merchant", merchant)
        put("counterpartyName", counterpartyName)
        put("rawBody", rawBody)
        put("scenario", scenario)
        put("detailSummary", detailSummary)
        if (amount == null) {
            put("amount", JSONObject.NULL)
        } else {
            put("amount", amount)
        }
        put("entryType", entryType)
        put("channel", channel)
        put("capturedAt", capturedAt)
        put("postedAtMillis", postedAtMillis)
        put("confidence", confidence)
        put("defaultCategoryId", defaultCategoryId)
        put("profileId", profileId)
        put("mergeKey", mergeKey)
        put("eventKind", eventKind)
    }

    companion object {
        fun fromJson(json: JSONObject): NotificationEvent = NotificationEvent(
            packageName = json.optString("packageName"),
            source = json.optString("source"),
            title = json.optString("title"),
            merchant = json.optString("merchant"),
            counterpartyName = json.optString("counterpartyName"),
            rawBody = json.optString("rawBody"),
            scenario = json.optString("scenario"),
            detailSummary = json.optString("detailSummary"),
            amount = if (json.isNull("amount")) null else json.optDouble("amount"),
            entryType = json.optString("entryType"),
            channel = json.optString("channel"),
            capturedAt = json.optString("capturedAt"),
            postedAtMillis = json.optLong("postedAtMillis"),
            confidence = json.optDouble("confidence"),
            defaultCategoryId = json.optString("defaultCategoryId"),
            profileId = json.optInt("profileId"),
            mergeKey = json.optString("mergeKey"),
            eventKind = json.optString("eventKind"),
        )
    }
}
