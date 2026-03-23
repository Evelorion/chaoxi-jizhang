package com.aline.jier.jier

import java.security.MessageDigest
import java.time.Instant
import java.time.ZoneOffset
import java.time.format.DateTimeFormatter
import kotlin.math.abs

object CaptureLinking {
    private const val UNKNOWN_COUNTERPARTY = "未识别对象"
    private const val PAYMENT_MATCH_WINDOW_MS = 20 * 60 * 1000L
    private const val TRANSFER_MATCH_WINDOW_MS = 45 * 60 * 1000L
    private const val ENRICHMENT_MATCH_WINDOW_MS = 6 * 60 * 1000L
    private const val SHOPPING_FALLBACK_MATCH_WINDOW_MS = 8 * 60 * 1000L

    fun createCapture(event: NotificationEvent, existingId: String? = null): LedgerCapture {
        val amount = event.amount ?: error("amount-bearing event is required to create a capture")
        return LedgerCapture(
            id = existingId ?: stableCaptureId(event),
            title = buildTitle(
                source = event.source,
                scenario = event.scenario,
                merchant = event.merchant,
                counterpartyName = event.counterpartyName,
            ),
            merchant = event.merchant,
            counterpartyName = event.counterpartyName,
            rawBody = event.rawBody.take(420),
            scenario = event.scenario,
            detailSummary = event.detailSummary.take(420),
            amount = amount,
            entryType = event.entryType,
            channel = event.channel,
            source = event.source,
            capturedAt = event.capturedAt,
            postedAtMillis = event.postedAtMillis,
            confidence = event.confidence,
            defaultCategoryId = event.defaultCategoryId,
            profileId = event.profileId,
            mergeKey = event.mergeKey,
            relatedSources = emptyList(),
        )
    }

    fun mergeCapture(existing: LedgerCapture, event: NotificationEvent): LedgerCapture {
        val promoteEvent = shouldPromoteEvent(existing, event)
        val primarySource = if (promoteEvent) event.source else existing.source
        val primaryScenario = if (promoteEvent && event.scenario.isNotBlank()) event.scenario else existing.scenario
        val primaryChannel = when {
            promoteEvent && event.channel.isNotBlank() -> event.channel
            existing.channel != "other" -> existing.channel
            event.channel.isNotBlank() -> event.channel
            else -> existing.channel
        }
        val primaryCounterpartyName = chooseCounterpartyName(
            existing = existing.counterpartyName,
            incoming = event.counterpartyName,
            promoteIncoming = promoteEvent,
        )
        val primaryMerchant = chooseMerchant(existing.merchant, event.merchant, promoteEvent)
        val relatedSources = buildList {
            if (primarySource != existing.source) add(existing.source)
            addAll(existing.relatedSources)
            if (primarySource != event.source) add(event.source)
        }.filter { it.isNotBlank() && it != primarySource }.distinct()

        val defaultCategoryId = when {
            event.defaultCategoryId == "shopping" -> "shopping"
            existing.defaultCategoryId == "shopping" -> "shopping"
            primarySource in shoppingSources -> "shopping"
            else -> event.defaultCategoryId.ifBlank { existing.defaultCategoryId }
        }

        val postedAtMillis = minOf(existing.postedAtMillis, event.postedAtMillis)
        val capturedAt = Instant.ofEpochMilli(postedAtMillis)
            .atOffset(ZoneOffset.UTC)
            .format(DateTimeFormatter.ISO_OFFSET_DATE_TIME)

        return existing.copy(
            title = buildTitle(
                source = primarySource,
                scenario = primaryScenario,
                merchant = primaryMerchant,
                counterpartyName = primaryCounterpartyName,
            ),
            merchant = primaryMerchant,
            counterpartyName = primaryCounterpartyName,
            rawBody = mergeParagraphs(existing.rawBody, event.rawBody).take(420),
            scenario = primaryScenario,
            detailSummary = mergeParagraphs(existing.detailSummary, event.detailSummary).take(420),
            channel = primaryChannel,
            source = primarySource,
            capturedAt = capturedAt,
            postedAtMillis = postedAtMillis,
            confidence = maxOf(existing.confidence, event.confidence).coerceAtMost(0.99),
            defaultCategoryId = defaultCategoryId,
            mergeKey = chooseMergeKey(existing.mergeKey, event.mergeKey),
            relatedSources = relatedSources,
        )
    }

    fun matchesCapture(capture: LedgerCapture, event: NotificationEvent): Boolean {
        if (capture.profileId != event.profileId) return false
        if (capture.entryType != event.entryType) return false

        val delta = abs(capture.postedAtMillis - event.postedAtMillis)
        if (delta > matchWindowMillis(capture, event)) return false

        if (event.amount != null && abs(capture.amount - event.amount) > 0.009) {
            return false
        }

        val keyOverlap = keysOverlap(capture.mergeKey, event.mergeKey) ||
            keysOverlap(capture.counterpartyName, event.counterpartyName) ||
            keysOverlap(capture.merchant, event.merchant)

        if (event.eventKind == "confirmation") {
            return capture.scenario.contains("transfer", ignoreCase = true) && keyOverlap
        }

        val captureHasShoppingContext =
            capture.source in shoppingSources || capture.relatedSources.any { it in shoppingSources }
        if (captureHasShoppingContext || event.source in shoppingSources) {
            return keyOverlap || delta <= SHOPPING_FALLBACK_MATCH_WINDOW_MS
        }

        return keyOverlap || delta <= 60 * 1000L
    }

    fun sourceLabel(source: String): String = when (source) {
        "wechat" -> "微信"
        "alipay" -> "支付宝"
        "googlePay" -> "Google Pay"
        "taobao" -> "淘宝"
        "jd" -> "京东"
        "pinduoduo" -> "拼多多"
        "xianyu" -> "闲鱼"
        else -> "通知"
    }

    fun scenarioLabel(scenario: String): String = when (scenario) {
        "codePayment" -> "收款码付款"
        "codeReceipt" -> "收款码收款"
        "transferPayment" -> "转账支出"
        "transferReceipt" -> "转账收入"
        "merchantPayment" -> "商家付款"
        "merchantReceipt" -> "商家收款"
        "walletPayment" -> "钱包付款"
        "walletReceipt" -> "钱包收款"
        "refund" -> "退款"
        "platformPayment" -> "平台支付"
        "platformRefund" -> "平台退款"
        "receipt" -> "收款"
        else -> "付款"
    }

    fun isPaymentSource(source: String): Boolean = source in paymentSources

    fun isShoppingSource(source: String): Boolean = source in shoppingSources

    private val paymentSources = setOf("wechat", "alipay", "googlePay")
    private val shoppingSources = setOf("taobao", "jd", "pinduoduo", "xianyu")

    private fun stableCaptureId(event: NotificationEvent): String {
        val raw = listOf(
            event.profileId.toString(),
            event.source,
            event.entryType,
            event.amount?.toString().orEmpty(),
            event.mergeKey,
            event.postedAtMillis.toString(),
        ).joinToString("|")
        val hash = MessageDigest.getInstance("SHA-256").digest(raw.toByteArray())
        return hash.joinToString(separator = "") { "%02x".format(it) }.take(24)
    }

    private fun buildTitle(
        source: String,
        scenario: String,
        merchant: String,
        counterpartyName: String,
    ): String {
        val displayTarget = chooseDisplayTarget(source, merchant, counterpartyName)
        return if (displayTarget.isBlank()) {
            "${sourceLabel(source)}${scenarioLabel(scenario)}"
        } else {
            "${sourceLabel(source)}${scenarioLabel(scenario)} · $displayTarget"
        }
    }

    private fun chooseMerchant(existing: String, incoming: String, promoteIncoming: Boolean): String {
        val existingGeneric = isGenericCounterparty(existing)
        val incomingGeneric = isGenericCounterparty(incoming)
        return when {
            incoming.isBlank() || incomingGeneric -> existing
            existing.isBlank() || existingGeneric -> incoming
            promoteIncoming -> incoming
            incoming.length > existing.length -> incoming
            else -> existing
        }
    }

    private fun chooseCounterpartyName(
        existing: String,
        incoming: String,
        promoteIncoming: Boolean,
    ): String {
        val existingGeneric = isGenericCounterparty(existing)
        val incomingGeneric = isGenericCounterparty(incoming)
        return when {
            incoming.isBlank() || incomingGeneric -> existing
            existing.isBlank() || existingGeneric -> incoming
            promoteIncoming -> incoming
            incoming.length > existing.length -> incoming
            else -> existing
        }
    }

    private fun isGenericCounterparty(value: String): Boolean {
        if (value.isBlank() || value == UNKNOWN_COUNTERPARTY) return true
        return value.endsWith("付款") || value.endsWith("收款") || value.endsWith("支付")
    }

    private fun chooseDisplayTarget(
        source: String,
        merchant: String,
        counterpartyName: String,
    ): String {
        val cleanedCounterparty = counterpartyName.takeUnless(::isGenericCounterparty).orEmpty()
        val cleanedMerchant = merchant.takeUnless(::isGenericCounterparty).orEmpty()
        return when {
            source in shoppingSources && cleanedMerchant.isNotBlank() -> cleanedMerchant
            cleanedCounterparty.isNotBlank() -> cleanedCounterparty
            cleanedMerchant.isNotBlank() -> cleanedMerchant
            else -> ""
        }
    }

    private fun shouldPromoteEvent(existing: LedgerCapture, event: NotificationEvent): Boolean {
        if (event.amount == null) return false
        val existingPriority = sourcePriority(existing.source)
        val eventPriority = sourcePriority(event.source)
        return when {
            eventPriority > existingPriority -> true
            eventPriority < existingPriority -> false
            existing.channel == "other" && event.channel != "other" -> true
            existing.source in shoppingSources && event.source in paymentSources -> true
            else -> false
        }
    }

    private fun sourcePriority(source: String): Int = when {
        source in paymentSources -> 30
        source in shoppingSources -> 20
        else -> 0
    }

    private fun chooseMergeKey(existing: String, incoming: String): String {
        return when {
            incoming.isBlank() -> existing
            existing.isBlank() -> incoming
            incoming.length > existing.length -> incoming
            else -> existing
        }
    }

    private fun matchWindowMillis(capture: LedgerCapture, event: NotificationEvent): Long {
        return when {
            event.eventKind == "confirmation" || capture.scenario.contains("transfer", ignoreCase = true) ->
                TRANSFER_MATCH_WINDOW_MS
            capture.source in shoppingSources || event.source in shoppingSources ->
                PAYMENT_MATCH_WINDOW_MS
            else -> ENRICHMENT_MATCH_WINDOW_MS
        }
    }

    private fun keysOverlap(left: String, right: String): Boolean {
        val normalizedLeft = normalizeKey(left)
        val normalizedRight = normalizeKey(right)
        if (normalizedLeft.isBlank() || normalizedRight.isBlank()) return false
        return normalizedLeft == normalizedRight ||
            normalizedLeft.contains(normalizedRight) ||
            normalizedRight.contains(normalizedLeft)
    }

    private fun normalizeKey(value: String): String {
        return value.lowercase()
            .replace(Regex("""[\s\p{Punct}【】（）()\[\]·|]"""), "")
            .trim()
    }

    private fun mergeParagraphs(vararg parts: String): String {
        return parts
            .flatMap { text -> text.split('\n') }
            .map(String::trim)
            .filter(String::isNotBlank)
            .distinct()
            .joinToString("\n")
    }
}
