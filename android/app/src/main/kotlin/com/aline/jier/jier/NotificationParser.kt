package com.aline.jier.jier

import java.time.Instant
import java.time.ZoneOffset
import java.time.format.DateTimeFormatter
import java.util.Locale

object NotificationParser {
    private const val UNKNOWN_COUNTERPARTY = "未识别对象"
    private const val AMOUNT_PATTERN =
        """([0-9]{1,3}(?:,[0-9]{3})*(?:\.[0-9]{1,2})?|[0-9]+(?:\.[0-9]{1,2})?)"""

    private val genericTitleBlacklist = setOf(
        "你",
        "您",
        "对方",
        "對方",
        "付款人",
        "付款方",
        "收款人",
        "收款方",
        "payer",
        "payee",
        "微信",
        "微信支付",
        "微信轉帳",
        "微信转账",
        "微信收款商业版",
        "微信收款商業版",
        "转账助手",
        "轉帳助手",
        "支付宝",
        "支付寶",
        "支付宝通知",
        "支付寶通知",
        "google pay",
        "wallet",
        "淘宝",
        "京东",
        "拼多多",
        "闲鱼",
        "閒魚",
    )

    private val paymentKeywords = mapOf(
        "wechat" to listOf(
            "微信支付",
            "微信轉帳",
            "微信转账",
            "收款到账",
            "收款到帳",
            "转账收款",
            "轉帳收款",
            "成功收款",
            "付款成功",
            "支付成功",
            "向你转账",
            "向你轉帳",
            "已被接收",
            "對方已收款",
            "对方已收款",
        ),
        "alipay" to listOf(
            "支付宝",
            "支付寶",
            "收钱到账",
            "收錢到帳",
            "成功收款",
            "付款成功",
            "你已成功付款",
            "转账成功",
            "轉帳成功",
            "退款成功",
            "退款到账",
            "退款到帳",
        ),
        "googlePay" to listOf(
            "google pay",
            "gpay",
            "paid",
            "received",
            "purchase",
            "transfer",
            "refund",
        ),
        "taobao" to listOf(
            "订单支付成功",
            "訂單支付成功",
            "支付成功",
            "付款完成",
            "付款成功",
            "已支付",
            "下单成功",
            "下單成功",
            "订单支付",
            "訂單支付",
            "交易成功",
            "店铺",
            "店鋪",
            "卖家",
            "賣家",
            "宝贝",
            "寶貝",
            "商品",
            "退款成功",
            "退款到账",
            "退款到帳",
        ),
        "jd" to listOf(
            "支付成功",
            "付款成功",
            "已支付",
            "订单支付",
            "訂單支付",
            "退款成功",
            "退款到账",
            "退款到帳",
        ),
        "pinduoduo" to listOf(
            "支付成功",
            "付款成功",
            "已支付",
            "订单支付",
            "訂單支付",
            "退款成功",
            "退款到账",
            "退款到帳",
        ),
        "xianyu" to listOf(
            "支付成功",
            "付款成功",
            "已支付",
            "退款成功",
            "退款到账",
            "退款到帳",
            "交易成功",
            "收款成功",
        ),
    )

    private val shoppingNoiseKeywords = listOf(
        "发货",
        "發貨",
        "物流",
        "快递",
        "快遞",
        "签收",
        "簽收",
        "客服",
        "评价",
        "評價",
        "推荐",
        "推薦",
        "直播",
        "签到",
        "簽到",
        "优惠",
        "優惠",
        "红包",
        "紅包",
        "收藏",
        "关注",
        "關注",
        "上新",
        "出库",
        "出庫",
        "派送",
        "delivery",
        "shipped",
    )

    private val transferKeywords = listOf(
        "转账",
        "轉帳",
        "转賬",
        "轉賬",
        "transfer",
        "remittance",
    )

    private val acceptedTransferKeywords = listOf(
        "已被接收",
        "已被领取",
        "已被領取",
        "对方已收款",
        "對方已收款",
        "transfer accepted",
    )

    private val qrKeywords = listOf(
        "收款码",
        "收款碼",
        "收钱码",
        "收錢碼",
        "二维码",
        "二維碼",
        "扫码付款",
        "掃碼付款",
        "scan to pay",
    )

    private val expenseKeywords = listOf(
        "付款",
        "支付",
        "消费",
        "消費",
        "扣款",
        "支出",
        "购买",
        "購買",
        "下单",
        "下單",
        "pay",
        "paid",
        "purchase",
        "spent",
        "debit",
        "sent",
        "转账给",
        "轉帳給",
        "付款给",
        "付款給",
        "已支付",
    )

    private val incomeKeywords = listOf(
        "收款",
        "收钱",
        "收錢",
        "到账",
        "到帳",
        "入账",
        "入帳",
        "转入",
        "轉入",
        "退款",
        "received",
        "deposit",
        "income",
        "refund",
        "credit",
        "退款成功",
    )

    private val transferNameRegexes = listOf(
        Regex("""(?:^|[\s，,。])(?:你|您)(?:已)?(?:成功)?向([^¥￥$0-9，,。:：;；\s]{1,32}?)(?:發起|发起|轉帳|转账|付款|支付|收款碼|收款码|$|[¥￥$])"""),
        Regex("""(?:^|[\s，,。])(?:已向|已转给|已轉給|已付款给|已付款給)(?!你|您)([^¥￥$0-9，,。:：;；\s]{1,32}?)(?:發起|发起|轉帳|转账|付款|支付|收款碼|收款码|$|[¥￥$])"""),
        Regex("""(?:^|[\s，,。])向(?!你|您)([^¥￥$0-9，,。:：;；\s]{1,32}?)(?:轉帳|转账|付款|支付|收款碼|收款码)"""),
        Regex("""(?:转账给|轉帳給|轉給|转给|付款给|付款給)([^¥￥$0-9，,。:：;；\s]{1,32}?)(?:的?(?:轉帳|转账|付款|支付|收款碼|收款码|$|[¥￥$]))"""),
        Regex("""([^¥￥$0-9，,。:：;；\s]{1,32}?)(?:向你转账|向你轉帳|向您转账|向您轉帳|已向你付款|已向您付款|向你付款|向您付款)"""),
        Regex("""([^¥￥$0-9，,。:：;；\s]{1,32}?)(?:已收下你的转账|已收下你的轉帳|已接收你的转账|已接收你的轉帳|已领取你的转账|已領取你的轉帳)"""),
        Regex("""(?:来自|來自|from)\s*([^¥￥$0-9，,。:：;；\s]{1,32}?)(?:的?(?:轉帳|转账|付款|支付|收款|$))""", RegexOption.IGNORE_CASE),
        Regex("""(?:收款方|收款對象|收款对象|付款方|付款對象|付款对象|付款人|收款人|payer|payee)[：:\s]*([^¥￥$0-9，,。:：;；\s]{1,32})""", RegexOption.IGNORE_CASE),
        Regex("""(?:卖家|賣家|买家|買家)[：:\s]*([^¥￥$0-9，,。:：;；\s]{1,32})"""),
    )

    private val shoppingMerchantRegexes = listOf(
        Regex("""(?:店铺|店鋪|店家|商家|店名|賣家|卖家)[：:\s]*([^，,。:：;；]{2,36})"""),
        Regex("""(?:订单|訂單|商品|寶貝|宝贝)[：:\s]*([^，,。:：;；]{2,36})"""),
        Regex("""(?:于|於|在)\s*([^，,。:：;；]{2,36}?)(?:店铺|店鋪|下单|下單|付款|支付)"""),
    )

    private val amountRegexes = listOf(
        Regex("""(?:¥|￥|\$|HK\$|MOP\$|NT\$|USD|CNY|RMB)\s*$AMOUNT_PATTERN""", RegexOption.IGNORE_CASE),
        Regex("""$AMOUNT_PATTERN\s*(?:元|圓|块|塊)""", RegexOption.IGNORE_CASE),
        Regex("""(?:金额|金額|amount)[：: ]*$AMOUNT_PATTERN""", RegexOption.IGNORE_CASE),
        Regex("""(?:转账|轉帳|转賬|轉賬|收款|付款|支付|收钱|收錢|到账|到帳|退款|paid|received|debited|credited|refund)[^\d¥￥$]{0,20}(?:金额|金額|amount)?[：: ]*(?:¥|￥|\$|HK\$|MOP\$|NT\$)?\s*$AMOUNT_PATTERN""", RegexOption.IGNORE_CASE),
    )

    private val merchantishKeywords = listOf(
        "店",
        "店铺",
        "店鋪",
        "商家",
        "卖家",
        "賣家",
        "订单",
        "訂單",
        "商城",
        "超市",
        "mall",
        "shop",
        "store",
        "official",
        "客服",
        "旗舰",
        "旗艦",
    )

    fun parse(
        packageName: String,
        profileId: Int,
        title: String,
        body: String,
        postedAt: Long,
        titleBig: String = "",
        conversationTitle: String = "",
        subText: String = "",
        summaryText: String = "",
    ): NotificationEvent? {
        val source = detectSource(packageName) ?: return null
        val normalizedTitle = title.replace('\n', ' ').trim()
        val normalizedBody = body.replace('\n', ' ').trim()
        val normalizedTitleBig = titleBig.replace('\n', ' ').trim()
        val normalizedConversationTitle = conversationTitle.replace('\n', ' ').trim()
        val normalizedSubText = subText.replace('\n', ' ').trim()
        val normalizedSummaryText = summaryText.replace('\n', ' ').trim()

        val merged = listOf(
            normalizedTitle,
            normalizedTitleBig,
            normalizedConversationTitle,
            normalizedSubText,
            normalizedSummaryText,
            normalizedBody,
        )
            .filter { it.isNotBlank() }
            .distinct()
            .joinToString(" ")
            .trim()

        if (merged.isBlank() || !looksLikePayment(source, merged)) {
            return null
        }
        if (CaptureLinking.isShoppingSource(source) && looksLikeShoppingNoise(merged)) {
            return null
        }

        val amount = extractAmount(merged)
        val eventKind = inferEventKind(source, merged, amount)
        if (amount == null && eventKind == "capture") {
            return null
        }

        val entryType = inferEntryType(source, merged, amount, eventKind)
        val scenario = inferScenario(source, merged, entryType, amount, eventKind)
        val counterpartyName = extractCounterpartyName(
            source = source,
            scenario = scenario,
            title = normalizedTitle,
            titleBig = normalizedTitleBig,
            conversationTitle = normalizedConversationTitle,
            subText = normalizedSubText,
            summaryText = normalizedSummaryText,
            body = normalizedBody,
        )
        val merchant = extractMerchant(
            source = source,
            scenario = scenario,
            title = normalizedTitle,
            titleBig = normalizedTitleBig,
            conversationTitle = normalizedConversationTitle,
            subText = normalizedSubText,
            summaryText = normalizedSummaryText,
            body = normalizedBody,
            counterpartyName = counterpartyName,
        )
        val mergeKey = buildMergeKey(
            counterpartyName,
            merchant,
            normalizedTitle,
            normalizedConversationTitle,
            normalizedBody,
        )
        val defaultCategoryId = inferCategory(source, merged, merchant)
        val detailSummary = buildDetailSummary(
            source = source,
            scenario = scenario,
            merchant = merchant,
            counterpartyName = counterpartyName,
            entryType = entryType,
            amount = amount,
            rawNotification = merged,
            eventKind = eventKind,
        )
        val isoTime = Instant.ofEpochMilli(postedAt)
            .atOffset(ZoneOffset.UTC)
            .format(DateTimeFormatter.ISO_OFFSET_DATE_TIME)

        return NotificationEvent(
            packageName = packageName,
            source = source,
            title = CaptureLinking.sourceLabel(source),
            merchant = merchant,
            counterpartyName = counterpartyName,
            rawBody = merged.take(420),
            scenario = scenario,
            detailSummary = detailSummary.take(420),
            amount = amount,
            entryType = entryType,
            channel = inferChannel(source, merged),
            capturedAt = isoTime,
            postedAtMillis = postedAt,
            confidence = inferConfidence(source, merged, merchant, counterpartyName, scenario, amount, eventKind),
            defaultCategoryId = defaultCategoryId,
            profileId = profileId,
            mergeKey = mergeKey,
            eventKind = eventKind,
        )
    }

    private fun detectSource(packageName: String): String? = when (packageName) {
        "com.tencent.mm" -> "wechat"
        "com.eg.android.AlipayGphone" -> "alipay"
        "com.google.android.apps.walletnfcrel",
        "com.google.android.apps.nbu.paisa.user" -> "googlePay"
        "com.taobao.taobao" -> "taobao"
        "com.jingdong.app.mall" -> "jd"
        "com.xunmeng.pinduoduo" -> "pinduoduo"
        "com.taobao.idlefish" -> "xianyu"
        else -> null
    }

    private fun looksLikePayment(source: String, text: String): Boolean {
        val lowercase = text.lowercase()
        val sourceMatched = paymentKeywords[source].orEmpty().any { lowercase.contains(it.lowercase()) }
        val directionalMatched = expenseKeywords.any { lowercase.contains(it.lowercase()) } ||
            incomeKeywords.any { lowercase.contains(it.lowercase()) }
        val transferMatched = containsAny(lowercase, transferKeywords) || containsAny(lowercase, acceptedTransferKeywords)
        return sourceMatched || directionalMatched || transferMatched || extractAmount(text) != null
    }

    private fun looksLikeShoppingNoise(text: String): Boolean {
        val lowercase = text.lowercase()
        val hasNoise = shoppingNoiseKeywords.any { lowercase.contains(it.lowercase()) }
        val hasPaymentSignal = listOf(
            "支付",
            "付款",
            "退款",
            "已支付",
            "交易成功",
            "订单支付成功",
            "訂單支付成功",
            "付款完成",
            "success",
            "refund",
            "paid",
        )
            .any { lowercase.contains(it.lowercase()) } || extractAmount(text) != null
        return hasNoise && !hasPaymentSignal
    }

    private fun inferEventKind(source: String, text: String, amount: Double?): String {
        val lowercase = text.lowercase()
        return when {
            amount != null -> "capture"
            CaptureLinking.isShoppingSource(source) -> "enrichment"
            containsAny(lowercase, acceptedTransferKeywords) -> "confirmation"
            source == "wechat" && lowercase.contains("[轉賬]") -> "confirmation"
            else -> "capture"
        }
    }

    private fun extractAmount(text: String): Double? {
        amountRegexes.forEach { regex ->
            val match = regex.find(text) ?: return@forEach
            val amountText = match.groupValues.getOrNull(1)?.replace(",", "") ?: return@forEach
            val amount = amountText.toDoubleOrNull()
            if (amount != null && amount > 0) {
                return amount
            }
        }
        return null
    }

    private fun inferEntryType(source: String, text: String, amount: Double?, eventKind: String): String {
        val lowercase = text.lowercase()
        if (CaptureLinking.isShoppingSource(source)) {
            return if (lowercase.contains("退款")) "income" else "expense"
        }
        if (eventKind == "confirmation" && source == "wechat") {
            if (containsAny(lowercase, listOf("对方已收款", "對方已收款", "已被接收"))) {
                return "expense"
            }
        }
        if (containsAny(lowercase, listOf("向你转账", "向你轉帳", "向您转账", "向您轉帳", "已向你付款", "已向您付款"))) {
            return "income"
        }
        if (containsAny(lowercase, listOf("转账给", "轉帳給", "付款给", "付款給", "你向", "您向", "已向", "已转给", "已轉給"))) {
            return "expense"
        }
        if (lowercase.contains("退款")) {
            return "income"
        }
        val incomeHits = incomeKeywords.count { lowercase.contains(it.lowercase()) }
        val expenseHits = expenseKeywords.count { lowercase.contains(it.lowercase()) }
        return when {
            incomeHits > expenseHits -> "income"
            expenseHits > incomeHits -> "expense"
            amount == null && eventKind == "confirmation" -> "expense"
            else -> "expense"
        }
    }

    private fun inferScenario(
        source: String,
        text: String,
        entryType: String,
        amount: Double?,
        eventKind: String,
    ): String {
        val lowercase = text.lowercase()
        val isTransferScene = containsAny(lowercase, transferKeywords) || containsAny(lowercase, acceptedTransferKeywords)
        val isCodeScene = containsAny(lowercase, qrKeywords)

        return when {
            lowercase.contains("退款") && CaptureLinking.isShoppingSource(source) -> "platformRefund"
            lowercase.contains("退款") -> "refund"
            isCodeScene && entryType == "expense" -> "codePayment"
            isCodeScene && entryType == "income" -> "codeReceipt"
            isTransferScene && entryType == "expense" -> "transferPayment"
            isTransferScene && entryType == "income" -> "transferReceipt"
            CaptureLinking.isShoppingSource(source) && amount != null && entryType == "expense" -> "platformPayment"
            CaptureLinking.isShoppingSource(source) && amount != null && entryType == "income" -> "platformRefund"
            source == "googlePay" && entryType == "expense" -> "walletPayment"
            source == "googlePay" && entryType == "income" -> "walletReceipt"
            entryType == "income" -> "receipt"
            eventKind == "enrichment" -> "merchantPayment"
            else -> "merchantPayment"
        }
    }

    private fun extractCounterpartyName(
        source: String,
        scenario: String,
        title: String,
        titleBig: String,
        conversationTitle: String,
        subText: String,
        summaryText: String,
        body: String,
    ): String {
        val merged = listOf(title, titleBig, conversationTitle, subText, summaryText, body)
            .filter { it.isNotBlank() }
            .joinToString(" ")
        val lowercase = merged.lowercase()

        val shouldTryDirectName = scenario.contains("transfer", ignoreCase = true) ||
            scenario == "receipt" ||
            scenario == "codeReceipt" ||
            scenario == "codePayment" ||
            containsAny(
                lowercase,
                listOf("向你", "向您", "你向", "您向", "已向", "已转给", "已轉給", "付款人", "收款方", "收款人", "付款方", "from", "payer", "payee", "卖家", "賣家", "买家", "買家"),
            )

        if (!shouldTryDirectName && CaptureLinking.isShoppingSource(source)) {
            return ""
        }

        transferNameRegexes.forEach { regex ->
            val match = regex.find(merged)?.groupValues?.getOrNull(1).orEmpty()
            val cleaned = sanitizeCounterparty(match)
            if (looksLikePersonNameCandidate(cleaned)) {
                return cleaned
            }
        }

        val fallbackCandidates = buildList {
            add(conversationTitle)
            add(titleBig)
            add(title)
            add(subText)
            add(summaryText)
            if (shouldTryDirectName) {
                add(body)
            }
        }
        for (candidate in fallbackCandidates) {
            val cleaned = sanitizeCounterparty(candidate)
            if (looksLikePersonNameCandidate(cleaned)) {
                return cleaned
            }
        }

        return ""
    }

    private fun extractMerchant(
        source: String,
        scenario: String,
        title: String,
        titleBig: String,
        conversationTitle: String,
        subText: String,
        summaryText: String,
        body: String,
        counterpartyName: String,
    ): String {
        val merged = listOf(title, titleBig, conversationTitle, subText, summaryText, body)
            .filter { it.isNotBlank() }
            .joinToString(" ")

        if (CaptureLinking.isShoppingSource(source)) {
            shoppingMerchantRegexes.forEach { regex ->
                val match = regex.find(merged)?.groupValues?.getOrNull(1).orEmpty()
                val cleaned = sanitizeCounterparty(match)
                if (looksLikeMerchantCandidate(cleaned)) {
                    return cleaned
                }
            }
        }

        if (counterpartyName.isNotBlank() &&
            (scenario.contains("transfer", ignoreCase = true) ||
                scenario == "receipt" ||
                scenario == "codeReceipt" ||
                scenario == "codePayment")
        ) {
            return UNKNOWN_COUNTERPARTY
        }

        val candidateFallbacks = listOf(conversationTitle, titleBig, title, subText, summaryText)
        for (candidate in candidateFallbacks) {
            val cleaned = sanitizeCounterparty(candidate)
            if (looksLikeMerchantCandidate(cleaned) && cleaned != counterpartyName) {
                return cleaned
            }
        }

        return if (CaptureLinking.isShoppingSource(source)) {
            CaptureLinking.sourceLabel(source)
        } else {
            UNKNOWN_COUNTERPARTY
        }
    }

    private fun sanitizeCounterparty(raw: String): String {
        if (raw.isBlank()) return UNKNOWN_COUNTERPARTY
        var value = raw
            .replace('\n', ' ')
            .replace(Regex("""【[^】]+】"""), " ")
            .replace(Regex("""\[(?:轉賬|转账|轉帳)]"""), " ")
            .replace(Regex("""[\[\]()（）]"""), " ")

        listOf(
            "微信支付",
            "微信轉帳",
            "微信转账",
            "支付宝",
            "支付寶",
            "淘宝",
            "京东",
            "拼多多",
            "闲鱼",
            "閒魚",
            "通知",
            "成功",
            "到账",
            "到帳",
            "付款",
            "支付",
            "收款",
            "收钱",
            "收錢",
            "扫码",
            "掃碼",
            "二维码",
            "二維碼",
            "轉賬",
            "轉帳",
            "转账",
            "向你转账",
            "向你轉帳",
            "向您转账",
            "向您轉帳",
            "对方已收款",
            "對方已收款",
            "已被接收",
            "已支付",
            "支付成功",
            "退款成功",
            "订单",
            "訂單",
            "卖家",
            "賣家",
            "买家",
            "買家",
            "你",
            "您",
            "对方",
            "對方",
            "转账助手",
            "轉帳助手",
            "付款人",
            "收款方",
            "付款方",
            "收款人",
        ).forEach { token ->
            value = value.replace(token, " ", ignoreCase = true)
        }

        value = value
            .replace(Regex("""(?:¥|￥|\$|HK\$|MOP\$|NT\$)\s*$AMOUNT_PATTERN""", RegexOption.IGNORE_CASE), " ")
            .replace(Regex("""$AMOUNT_PATTERN\s*(?:元|圓|块|塊)""", RegexOption.IGNORE_CASE), " ")
            .replace(Regex("""\s+"""), " ")
            .trim(' ', '，', ',', '。', ':', '：', ';', '；', '-', '·', '|')

        return value.ifBlank { UNKNOWN_COUNTERPARTY }.take(36)
    }

    private fun looksLikeNameCandidate(candidate: String): Boolean {
        if (candidate.isBlank() || candidate == UNKNOWN_COUNTERPARTY) return false
        if (genericTitleBlacklist.contains(candidate.lowercase(Locale.ROOT))) return false
        return !Regex("""(?:¥|￥|\$|HK\$|MOP\$|NT\$)\s*$AMOUNT_PATTERN|$AMOUNT_PATTERN\s*(?:元|圓|块|塊)""", RegexOption.IGNORE_CASE)
            .containsMatchIn(candidate)
    }

    private fun looksLikePersonNameCandidate(candidate: String): Boolean {
        if (!looksLikeNameCandidate(candidate)) return false
        val lower = candidate.lowercase(Locale.ROOT)
        return merchantishKeywords.none { lower.contains(it.lowercase(Locale.ROOT)) }
    }

    private fun looksLikeMerchantCandidate(candidate: String): Boolean {
        return looksLikeNameCandidate(candidate)
    }

    private fun buildMergeKey(vararg parts: String): String {
        val candidate = parts
            .map(::sanitizeCounterparty)
            .firstOrNull(::looksLikeNameCandidate)
            .orEmpty()
        return candidate.lowercase(Locale.ROOT)
            .replace(Regex("""[\s\p{Punct}【】（）()\[\]·|]"""), "")
            .ifBlank { "generic" }
            .take(40)
    }

    private fun inferChannel(source: String, text: String): String {
        val lowercase = text.lowercase()
        return when {
            source == "wechat" -> "wechatPay"
            source == "alipay" -> "alipay"
            source == "googlePay" -> "googlePay"
            lowercase.contains("微信") || lowercase.contains("wechat") -> "wechatPay"
            lowercase.contains("支付寶") || lowercase.contains("支付宝") || lowercase.contains("花唄") || lowercase.contains("花呗") ->
                "alipay"
            lowercase.contains("银行卡") || lowercase.contains("銀行卡") || lowercase.contains("bank card") ->
                "bankCard"
            else -> "other"
        }
    }

    private fun inferCategory(source: String, text: String, merchant: String): String {
        if (CaptureLinking.isShoppingSource(source)) {
            return "shopping"
        }
        val lowercase = "$text $merchant".lowercase()
        val mapping = listOf(
            "food" to listOf("咖啡", "餐", "外卖", "外賣", "coffee", "tea", "奶茶"),
            "mobility" to listOf("滴滴", "地铁", "地鐵", "公交", "uber", "taxi", "高铁", "高鐵"),
            "housing" to listOf("房租", "物业", "物業", "水费", "水費", "电费", "電費"),
            "health" to listOf("医院", "醫院", "药", "藥", "clinic", "pharmacy"),
            "education" to listOf("课程", "課程", "教材", "book", "udemy", "coursera"),
            "pets" to listOf("宠", "寵", "pet", "猫", "貓", "狗"),
            "digital" to listOf("spotify", "icloud", "google", "drive", "netflix", "youtube"),
            "entertainment" to listOf("影院", "电影", "電影", "游戏", "遊戲", "steam", "ktv"),
            "shopping" to listOf("淘宝", "京东", "京東", "拼多多", "闲鱼", "閒魚", "mall", "store", "shop", "超市"),
        )
        return mapping.firstOrNull { (_, keywords) ->
            keywords.any { lowercase.contains(it.lowercase()) }
        }?.first ?: "shopping"
    }

    private fun buildDetailSummary(
        source: String,
        scenario: String,
        merchant: String,
        counterpartyName: String,
        entryType: String,
        amount: Double?,
        rawNotification: String,
        eventKind: String,
    ): String {
        return buildString {
            append("来源：")
            append(CaptureLinking.sourceLabel(source))
            append('\n')
            append("场景：")
            append(CaptureLinking.scenarioLabel(scenario))
            append('\n')
            append("类型：")
            append(
                when (eventKind) {
                    "confirmation" -> "确认通知"
                    "enrichment" -> "补充通知"
                    else -> "直接入账"
                },
            )
            if (counterpartyName.isNotBlank()) {
                append('\n')
                append(if (entryType == "income") "付款人：" else "收款方：")
                append(counterpartyName)
            }
            if (merchant.isNotBlank() && merchant != UNKNOWN_COUNTERPARTY && merchant != counterpartyName) {
                append('\n')
                append(
                    when {
                        CaptureLinking.isShoppingSource(source) -> "店铺："
                        else -> "商户："
                    },
                )
                append(merchant)
            }
            if (amount != null) {
                append('\n')
                append("金额：¥")
                append(String.format(Locale.US, "%.2f", amount))
            }
            append('\n')
            append("通知：")
            append(rawNotification)
        }
    }

    private fun inferConfidence(
        source: String,
        text: String,
        merchant: String,
        counterpartyName: String,
        scenario: String,
        amount: Double?,
        eventKind: String,
    ): Double {
        var score = 0.54
        if (merchant != UNKNOWN_COUNTERPARTY) score += 0.08
        if (counterpartyName.isNotBlank()) score += 0.10
        if (paymentKeywords[source].orEmpty().any { text.contains(it, ignoreCase = true) }) score += 0.12
        if (amount != null) score += 0.10
        if (scenario.contains("transfer", ignoreCase = true)) score += 0.06
        if (CaptureLinking.isShoppingSource(source)) score += 0.04
        if (eventKind != "capture") score -= 0.05
        return score.coerceIn(0.4, 0.97)
    }

    private fun containsAny(text: String, keywords: List<String>): Boolean {
        return keywords.any { text.contains(it.lowercase(Locale.ROOT)) }
    }
}
