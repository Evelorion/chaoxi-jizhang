package com.aline.jier.jier

import android.app.Notification
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.app.Service
import android.content.Context
import android.content.Intent
import android.os.Build
import android.os.IBinder

/**
 * 自动记账的"后台常驻"服务。
 *
 * 它的作用不是自己跑模型，而是**让 App 进程在切后台/锁屏后不被立刻冻结**：
 * 只要队列里还有待处理的支付通知，就用一个前台服务把进程留住，
 * Flutter 侧的定时器就能继续把队列消化掉；队列空了就自己停掉，不白耗电。
 */
class CaptureDrainService : Service() {
    override fun onBind(intent: Intent?): IBinder? = null

    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
        val pending = intent?.getIntExtra(EXTRA_PENDING, 0) ?: 0
        startForeground(NOTIFICATION_ID, buildNotification(pending))
        return START_NOT_STICKY
    }

    private fun buildNotification(pending: Int): Notification {
        val manager = getSystemService(Context.NOTIFICATION_SERVICE) as NotificationManager
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            val channel = NotificationChannel(
                CHANNEL_ID,
                "自动记账",
                NotificationManager.IMPORTANCE_MIN,
            )
            channel.description = "队列里还有支付通知没整理时显示"
            manager.createNotificationChannel(channel)
        }
        val openApp = PendingIntent.getActivity(
            this,
            0,
            Intent(this, MainActivity::class.java),
            PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE,
        )
        val builder = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            Notification.Builder(this, CHANNEL_ID)
        } else {
            @Suppress("DEPRECATION")
            Notification.Builder(this)
        }
        return builder
            .setContentTitle("潮汐账本正在整理账单")
            .setContentText(
                if (pending > 0) "还有 $pending 条通知等着生成账单" else "正在整理账单",
            )
            .setSmallIcon(android.R.drawable.stat_notify_sync)
            .setContentIntent(openApp)
            .setOngoing(true)
            .build()
    }

    companion object {
        const val CHANNEL_ID = "chaoxi_capture_drain"
        const val NOTIFICATION_ID = 8801
        const val EXTRA_PENDING = "pending"

        fun start(context: Context, pending: Int) {
            val intent = Intent(context, CaptureDrainService::class.java)
                .putExtra(EXTRA_PENDING, pending)
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
                context.startForegroundService(intent)
            } else {
                context.startService(intent)
            }
        }

        fun stop(context: Context) {
            context.stopService(Intent(context, CaptureDrainService::class.java))
        }
    }
}
