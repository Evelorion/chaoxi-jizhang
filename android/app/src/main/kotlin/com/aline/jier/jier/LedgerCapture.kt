package com.aline.jier.jier

import org.json.JSONArray
import org.json.JSONObject

data class LedgerCapture(
    val id: String,
    val title: String,
    val merchant: String,
    val counterpartyName: String = "",
    val rawBody: String,
    val scenario: String,
    val detailSummary: String,
    val amount: Double,
    val entryType: String,
    val channel: String,
    val source: String,
    val capturedAt: String,
    val postedAtMillis: Long,
    val confidence: Double,
    val defaultCategoryId: String,
    val profileId: Int,
    val mergeKey: String,
    val relatedSources: List<String>,
) {
    fun toJson(): JSONObject = JSONObject().apply {
        put("id", id)
        put("title", title)
        put("merchant", merchant)
        put("counterpartyName", counterpartyName)
        put("rawBody", rawBody)
        put("scenario", scenario)
        put("detailSummary", detailSummary)
        put("amount", amount)
        put("entryType", entryType)
        put("channel", channel)
        put("source", source)
        put("capturedAt", capturedAt)
        put("postedAtMillis", postedAtMillis)
        put("confidence", confidence)
        put("defaultCategoryId", defaultCategoryId)
        put("profileId", profileId)
        put("mergeKey", mergeKey)
        put("relatedSources", JSONArray().apply {
            relatedSources.forEach(::put)
        })
    }

    fun toMap(): Map<String, Any> = mapOf(
        "id" to id,
        "title" to title,
        "merchant" to merchant,
        "counterpartyName" to counterpartyName,
        "rawBody" to rawBody,
        "scenario" to scenario,
        "detailSummary" to detailSummary,
        "amount" to amount,
        "entryType" to entryType,
        "channel" to channel,
        "source" to source,
        "capturedAt" to capturedAt,
        "postedAtMillis" to postedAtMillis,
        "confidence" to confidence,
        "defaultCategoryId" to defaultCategoryId,
        "profileId" to profileId,
        "mergeKey" to mergeKey,
        "relatedSources" to relatedSources,
    )

    companion object {
        fun fromJson(json: JSONObject): LedgerCapture = LedgerCapture(
            id = json.optString("id"),
            title = json.optString("title"),
            merchant = json.optString("merchant"),
            counterpartyName = json.optString("counterpartyName"),
            rawBody = json.optString("rawBody"),
            scenario = json.optString("scenario"),
            detailSummary = json.optString("detailSummary"),
            amount = json.optDouble("amount"),
            entryType = json.optString("entryType"),
            channel = json.optString("channel"),
            source = json.optString("source"),
            capturedAt = json.optString("capturedAt"),
            postedAtMillis = json.optLong("postedAtMillis"),
            confidence = json.optDouble("confidence"),
            defaultCategoryId = json.optString("defaultCategoryId"),
            profileId = json.optInt("profileId"),
            mergeKey = json.optString("mergeKey"),
            relatedSources = buildList {
                val array = json.optJSONArray("relatedSources") ?: JSONArray()
                for (index in 0 until array.length()) {
                    val value = array.optString(index)
                    if (value.isNotBlank()) {
                        add(value)
                    }
                }
            },
        )
    }
}
