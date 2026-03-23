package com.aline.jier.jier

import android.app.Notification
import android.service.notification.NotificationListenerService
import android.service.notification.StatusBarNotification
import android.util.Log

class LedgerNotificationListenerService : NotificationListenerService() {
    override fun onNotificationPosted(sbn: StatusBarNotification?) {
        sbn ?: return
        val notification = sbn.notification ?: return
        if (notification.flags and Notification.FLAG_GROUP_SUMMARY != 0) {
            return
        }

        val extras = notification.extras ?: return
        val title = extras.getCharSequence(Notification.EXTRA_TITLE)?.toString().orEmpty()
        val titleBig = extras.getCharSequence(Notification.EXTRA_TITLE_BIG)?.toString().orEmpty()
        val conversationTitle = extras.getCharSequence(Notification.EXTRA_CONVERSATION_TITLE)?.toString().orEmpty()
        val subText = extras.getCharSequence(Notification.EXTRA_SUB_TEXT)?.toString().orEmpty()
        val summaryText = extras.getCharSequence(Notification.EXTRA_SUMMARY_TEXT)?.toString().orEmpty()
        val infoText = extras.getCharSequence(Notification.EXTRA_INFO_TEXT)?.toString().orEmpty()
        val tickerText = notification.tickerText?.toString().orEmpty()
        val profileId = resolveProfileId(sbn)
        val textLines = extras.getCharSequenceArray(Notification.EXTRA_TEXT_LINES)
            ?.map { it?.toString().orEmpty().trim() }
            ?.filter { it.isNotBlank() }
            .orEmpty()
        val body = buildString {
            append(extras.getCharSequence(Notification.EXTRA_TEXT)?.toString().orEmpty())
            val bigText = extras.getCharSequence(Notification.EXTRA_BIG_TEXT)?.toString().orEmpty()
            if (bigText.isNotBlank() && !contains(bigText)) {
                append(' ')
                append(bigText)
            }
            textLines.forEach { line ->
                if (!contains(line)) {
                    append(' ')
                    append(line)
                }
            }
            if (subText.isNotBlank() && !contains(subText)) {
                append(' ')
                append(subText)
            }
            if (summaryText.isNotBlank() && !contains(summaryText)) {
                append(' ')
                append(summaryText)
            }
            if (infoText.isNotBlank() && !contains(infoText)) {
                append(' ')
                append(infoText)
            }
            if (tickerText.isNotBlank() && !contains(tickerText)) {
                append(' ')
                append(tickerText)
            }
        }.trim()

        if (title.isBlank() && body.isBlank()) {
            return
        }

        val potentialPayment = looksLikePotentialPayment(
            sbn.packageName,
            title,
            titleBig,
            conversationTitle,
            subText,
            summaryText,
            body,
        )
        if (potentialPayment) {
            Log.d(
                "JierAutoCapture",
                "dispatch package=${sbn.packageName} profile=$profileId title=$title titleBig=$titleBig conversation=$conversationTitle",
            )
        }

        val capture = NotificationParser.parse(
            packageName = sbn.packageName,
            profileId = profileId,
            title = title,
            body = body,
            postedAt = sbn.postTime,
            titleBig = titleBig,
            conversationTitle = conversationTitle,
            subText = subText,
            summaryText = summaryText,
        )

        if (capture == null) {
            if (potentialPayment) {
                Log.d(
                    "JierAutoCapture",
                    "skipped package=${sbn.packageName} profile=$profileId title=$title titleBig=$titleBig conversation=$conversationTitle subText=$subText summary=$summaryText body=$body"
                )
            }
            return
        }

        handleNotificationEvent(capture)
    }

    private fun handleNotificationEvent(event: NotificationEvent) {
        var resolvedCapture = NotificationCorrelationStore.findMatchingCapture(applicationContext, event)
        if (event.amount != null) {
            var capture = resolvedCapture?.let { CaptureLinking.mergeCapture(it, event) }
                ?: CaptureLinking.createCapture(event)
            val pendingMatches =
                NotificationCorrelationStore.consumeMatchingPendingEvents(applicationContext, capture)
            pendingMatches.forEach { pendingEvent ->
                capture = CaptureLinking.mergeCapture(capture, pendingEvent)
            }
            AutoCaptureStore.upsert(applicationContext, capture)
            NotificationCorrelationStore.upsertRecentCapture(applicationContext, capture)
            Log.d(
                "JierAutoCapture",
                "captured source=${capture.source} related=${capture.relatedSources.joinToString()} profile=${capture.profileId} amount=${capture.amount} merchant=${capture.merchant} counterparty=${capture.counterpartyName}",
            )
            return
        }

        if (resolvedCapture != null) {
            val updatedCapture = CaptureLinking.mergeCapture(resolvedCapture, event)
            AutoCaptureStore.upsert(applicationContext, updatedCapture)
            NotificationCorrelationStore.upsertRecentCapture(applicationContext, updatedCapture)
            Log.d(
                "JierAutoCapture",
                "enriched source=${event.source} profile=${event.profileId} mergeKey=${event.mergeKey} captureId=${updatedCapture.id}",
            )
            return
        }

        NotificationCorrelationStore.enqueuePendingEvent(applicationContext, event)
        Log.d(
            "JierAutoCapture",
            "pending source=${event.source} profile=${event.profileId} kind=${event.eventKind} mergeKey=${event.mergeKey} merchant=${event.merchant} counterparty=${event.counterpartyName}",
        )
    }

    private fun looksLikePotentialPayment(
        packageName: String,
        title: String,
        titleBig: String,
        conversationTitle: String,
        subText: String,
        summaryText: String,
        body: String,
    ): Boolean {
        if (packageName !in setOf(
                "com.tencent.mm",
                "com.eg.android.AlipayGphone",
                "com.google.android.apps.walletnfcrel",
                "com.google.android.apps.nbu.paisa.user",
                "com.taobao.taobao",
                "com.jingdong.app.mall",
                "com.xunmeng.pinduoduo",
                "com.taobao.idlefish",
            )
        ) {
            return false
        }

        val merged = listOf(title, titleBig, conversationTitle, subText, summaryText, body)
            .filter { it.isNotBlank() }
            .joinToString(" ")
            .lowercase()
        val keywords = listOf(
            "微信",
            "微信支付",
            "微信轉帳",
            "微信转账",
            "支付宝",
            "支付寶",
            "google pay",
            "gpay",
            "淘宝",
            "京东",
            "拼多多",
            "闲鱼",
            "閒魚",
            "转账",
            "轉帳",
            "收款",
            "付款",
            "支付",
            "收钱",
            "收錢",
            "到账",
            "到帳",
            "已收款",
            "已被接收",
            "已支付",
            "退款成功",
            "paid",
            "received",
            "transfer",
        )
        return keywords.any { merged.contains(it.lowercase()) }
    }

    private fun resolveProfileId(sbn: StatusBarNotification): Int {
        val userText = sbn.user?.toString().orEmpty()
        return try {
            ProfileIdResolver.parse(userText) ?: run {
                Log.e(
                    "JierAutoCapture",
                    "profile parse fallback package=${sbn.packageName} rawUser=$userText",
                )
                0
            }
        } catch (error: Throwable) {
            Log.e(
                "JierAutoCapture",
                "profile parse crash-safe fallback package=${sbn.packageName} rawUser=$userText",
                error,
            )
            0
        }
    }
}
