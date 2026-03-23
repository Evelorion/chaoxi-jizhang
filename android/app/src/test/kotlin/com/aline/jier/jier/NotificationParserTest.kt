package com.aline.jier.jier

import org.junit.Assert.assertEquals
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

class NotificationParserTest {
    @Test
    fun `parses traditional chinese outgoing wechat transfer with counterparty name`() {
        val event = NotificationParser.parse(
            packageName = "com.tencent.mm",
            profileId = 0,
            title = "微信支付",
            body = "你向夏曦晨光轉帳 ¥88.80",
            postedAt = 1_700_000_000_000,
        )

        assertNotNull(event)
        assertEquals("wechat", event?.source)
        assertEquals("expense", event?.entryType)
        assertEquals("transferPayment", event?.scenario)
        assertEquals("夏曦晨光", event?.counterpartyName)
        assertEquals("未识别对象", event?.merchant)
        assertEquals("capture", event?.eventKind)
        assertEquals(88.80, event?.amount ?: 0.0, 0.001)
    }

    @Test
    fun `parses recipient from transfer helper notification wording`() {
        val event = NotificationParser.parse(
            packageName = "com.tencent.mm",
            profileId = 0,
            title = "转账助手",
            body = "已向李四转账 ¥66.00，等待对方收款",
            postedAt = 1_700_000_000_000,
        )

        assertNotNull(event)
        assertEquals("expense", event?.entryType)
        assertEquals("transferPayment", event?.scenario)
        assertEquals("李四", event?.counterpartyName)
        assertEquals(66.00, event?.amount ?: 0.0, 0.001)
    }

    @Test
    fun `parses incoming transfer payer name`() {
        val event = NotificationParser.parse(
            packageName = "com.tencent.mm",
            profileId = 0,
            title = "夏曦晨光",
            body = "夏曦晨光向你轉帳 ¥66.00",
            postedAt = 1_700_000_000_000,
        )

        assertNotNull(event)
        assertEquals("income", event?.entryType)
        assertEquals("transferReceipt", event?.scenario)
        assertEquals("夏曦晨光", event?.counterpartyName)
        assertTrue(event?.detailSummary?.contains("付款人：夏曦晨光") == true)
    }

    @Test
    fun `links transfer confirmation without amount back to previous transfer`() {
        val baseEvent = NotificationParser.parse(
            packageName = "com.tencent.mm",
            profileId = 999,
            title = "微信支付",
            body = "你向夏曦晨光轉帳 ¥120.00",
            postedAt = 1_700_000_000_000,
        )!!
        val baseCapture = CaptureLinking.createCapture(baseEvent)

        val confirmationEvent = NotificationParser.parse(
            packageName = "com.tencent.mm",
            profileId = 999,
            title = "夏曦晨光",
            body = "[轉賬] 已被接收",
            postedAt = 1_700_000_120_000,
        )

        assertNotNull(confirmationEvent)
        assertEquals("confirmation", confirmationEvent?.eventKind)
        assertNull(confirmationEvent?.amount)
        assertEquals("夏曦晨光", confirmationEvent?.counterpartyName)
        assertTrue(CaptureLinking.matchesCapture(baseCapture, confirmationEvent!!))

        val merged = CaptureLinking.mergeCapture(baseCapture, confirmationEvent)
        assertEquals(baseCapture.id, merged.id)
        assertEquals("夏曦晨光", merged.counterpartyName)
        assertTrue(merged.detailSummary.contains("确认通知"))
    }

    @Test
    fun `merges taobao payment detail into nearby alipay capture without losing names`() {
        val paymentEvent = NotificationParser.parse(
            packageName = "com.eg.android.AlipayGphone",
            profileId = 0,
            title = "支付宝",
            body = "你已成功付款 ￥129.00",
            postedAt = 1_700_000_000_000,
        )!!
        val paymentCapture = CaptureLinking.createCapture(paymentEvent)

        val taobaoEvent = NotificationParser.parse(
            packageName = "com.taobao.taobao",
            profileId = 0,
            title = "淘宝",
            body = "订单支付成功 ￥129.00 店铺：山野杂货店 卖家：夏曦晨光",
            postedAt = 1_700_000_060_000,
        )!!

        assertEquals("山野杂货店", taobaoEvent.merchant)
        assertEquals("夏曦晨光", taobaoEvent.counterpartyName)
        assertTrue(CaptureLinking.matchesCapture(paymentCapture, taobaoEvent))

        val merged = CaptureLinking.mergeCapture(paymentCapture, taobaoEvent)
        assertEquals("alipay", merged.source)
        assertTrue(merged.relatedSources.contains("taobao"))
        assertEquals("shopping", merged.defaultCategoryId)
        assertEquals("夏曦晨光", merged.counterpartyName)
        assertEquals("山野杂货店", merged.merchant)
        assertTrue(merged.detailSummary.contains("淘宝"))
    }

    @Test
    fun `matches taobao enrichment without amount to nearby payment when unique`() {
        val paymentEvent = NotificationParser.parse(
            packageName = "com.tencent.mm",
            profileId = 0,
            title = "微信支付",
            body = "支付成功 ￥88.00",
            postedAt = 1_700_000_000_000,
        )!!
        val paymentCapture = CaptureLinking.createCapture(paymentEvent)

        val taobaoEvent = NotificationParser.parse(
            packageName = "com.taobao.taobao",
            profileId = 0,
            title = "淘宝",
            body = "订单支付成功 付款完成 店铺：山野杂货店 卖家：夏曦晨光",
            postedAt = 1_700_000_300_000,
        )!!

        assertEquals("enrichment", taobaoEvent.eventKind)
        assertNull(taobaoEvent.amount)
        assertEquals("山野杂货店", taobaoEvent.merchant)
        assertTrue(CaptureLinking.matchesCapture(paymentCapture, taobaoEvent))

        val merged = CaptureLinking.mergeCapture(paymentCapture, taobaoEvent)
        assertEquals("wechat", merged.source)
        assertTrue(merged.relatedSources.contains("taobao"))
        assertEquals("山野杂货店", merged.merchant)
    }
}
