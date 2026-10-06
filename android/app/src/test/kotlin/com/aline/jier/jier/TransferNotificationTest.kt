package com.aline.jier.jier

import org.junit.Assert.assertEquals
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * 微信转账识别测试。
 *
 * 用真机上常见的转账通知文案跑解析器，确认三件事：
 * 1. 转账能被识别（不会因为不像"消费"被丢掉）；
 * 2. 类型是 transfer —— 转账既不算消费也不算收入，不进支出统计；
 * 3. 转出/转入方向、金额、对方名字都对。
 */
class TransferNotificationTest {
    private val wechat = "com.tencent.mm"

    private fun parse(title: String, body: String): NotificationEvent? =
        NotificationParser.parse(
            packageName = wechat,
            profileId = 0,
            title = title,
            body = body,
            postedAt = 1_760_000_000_000L,
        )

    @Test
    fun outgoingTransferIsNotSpending() {
        val event = parse("微信支付", "你已成功转账￥200.00给妈妈")
        assertNotNull("转账通知不能被丢掉", event)
        event!!
        assertEquals("transfer", event.entryType)
        assertEquals("transferPayment", event.scenario)
        assertEquals(200.0, event.amount!!, 0.001)
        assertEquals("妈妈", event.counterpartyName)
    }

    @Test
    fun incomingTransferIsNotIncome() {
        val event = parse("微信支付", "你收到一笔转账￥100.00，来自张三")
        assertNotNull(event)
        event!!
        assertEquals("transfer", event.entryType)
        assertEquals("transferReceipt", event.scenario)
        assertEquals(100.0, event.amount!!, 0.001)
        assertEquals("张三", event.counterpartyName)
    }

    @Test
    fun pendingTransferFromCounterparty() {
        val event = parse("微信支付", "张三向你转账￥100.00，请及时收款")
        assertNotNull(event)
        event!!
        assertEquals("transfer", event.entryType)
        assertEquals("transferReceipt", event.scenario)
        assertEquals(100.0, event.amount!!, 0.001)
        assertEquals("张三", event.counterpartyName)
    }

    @Test
    fun transferConfirmationKeepsAmount() {
        val event = parse("微信支付", "对方已收款￥200.00")
        assertNotNull(event)
        event!!
        assertEquals("transfer", event.entryType)
        assertEquals(200.0, event.amount!!, 0.001)
    }

    @Test
    fun transferUsesTransferCategory() {
        val event = parse("微信支付", "你已成功转账￥200.00给妈妈")
        assertNotNull(event)
        assertEquals("transfer", event!!.defaultCategoryId)
    }

    @Test
    fun normalMerchantPaymentStaysExpense() {
        val event = parse("微信支付", "微信支付 付款成功 ￥38.00")
        assertNotNull(event)
        event!!
        assertEquals("expense", event.entryType)
        assertTrue(
            "普通付款不应被判成转账",
            event.scenario != "transferPayment" && event.scenario != "transferReceipt",
        )
    }
}
