part of 'app.dart';

// Actually, _GlassCard is private in app.dart. We can use it directly since this is part of app.dart!

class _IntelliCard extends StatelessWidget {
  const _IntelliCard({required this.child, required this.color});
  final Widget child;
  final Color color;

  @override
  Widget build(BuildContext context) {
    return Container(
      decoration: BoxDecoration(
        color: color,
        borderRadius: BorderRadius.circular(20),
        border: Border.all(color: Colors.white.withValues(alpha: 0.4), width: 1.5),
        boxShadow: [
          BoxShadow(
            color: Colors.black.withValues(alpha: 0.04),
            blurRadius: 16,
            offset: const Offset(0, 8),
          ),
        ],
      ),
      child: child,
    );
  }
}

class BurnRatePredictorCard extends StatelessWidget {
  const BurnRatePredictorCard({required this.book, super.key});
  final LedgerBook book;

  @override
  Widget build(BuildContext context) {
    final now = DateTime.now();
    
    // Find all expense entries in current month
    final currentMonthExpenses = book.entries.where((e) => 
      e.type == EntryType.expense &&
      e.occurredAt.year == now.year &&
      e.occurredAt.month == now.month
    ).toList();
    
    double totalSpent = 0.0;
    for (var e in currentMonthExpenses) {
      totalSpent += e.amount;
    }

    int daysInMonth = DateTime(now.year, now.month + 1, 0).day;
    int currentDay = now.day;
    
    // If it's the very first day and no spend, predict 0.
    double dailySpend = currentDay > 1 ? totalSpent / (currentDay - 1) : totalSpent; // Wait, current day implies today is mostly done, let's use max(1, currentDay)
    if (dailySpend <= 0) dailySpend = 0.1; // avoid division by zero
    
    double budget = 4000.0; // Implicit default target
    if (book.budgets.isNotEmpty) {
      budget = book.budgets.fold(0.0, (sum, b) => sum + b.monthlyLimit);
    }
    
    double remainingBudget = budget - totalSpent;
    int daysLeftSupport = (remainingBudget / dailySpend).floor();
    
    int actualDaysLeft = daysInMonth - currentDay;
    
    bool isDanger = daysLeftSupport < actualDaysLeft;
    bool isOver = remainingBudget <= 0;

    String predictionText;
    Color cardColor;
    IconData icon;
    Color iconColor;

    if (isOver) {
      predictionText = "⚠️ 警报！目前开销已达 ${totalSpent.toStringAsFixed(2)}！本月预算已全面爆棚，建议立即收缩开支！";
      cardColor = const Color(0xFFFFF0F0);
      icon = Icons.warning_amber_rounded;
      iconColor = const Color(0xFFD32F2F);
    } else if (isDanger) {
      predictionText = "☔ 按照近 ${currentDay} 天的干饭频率（日均 ￥${dailySpend.toStringAsFixed(0)}），预测您的残余额度仅能支撑 ${daysLeftSupport} 天！将在月末前提前见底！";
      cardColor = const Color(0xFFFFF8E1);
      icon = Icons.umbrella;
      iconColor = const Color(0xFFF57C00);
    } else {
      predictionText = "☀️ 开销控制得当！按目前的日均 ￥${dailySpend.toStringAsFixed(0)} 的速度，到月底您还将余裕 ￥${(remainingBudget - dailySpend * actualDaysLeft).toStringAsFixed(0)}！";
      cardColor = const Color(0xFFF1FAEE);
      icon = Icons.wb_sunny;
      iconColor = const Color(0xFF388E3C);
    }
    
    if (totalSpent == 0) return const SizedBox.shrink();

    return Padding(
      padding: const EdgeInsets.only(bottom: 16.0),
      child: _IntelliCard(
        color: cardColor,
        child: Padding(
          padding: const EdgeInsets.all(16.0),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Icon(icon, color: iconColor, size: 28),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text('预算烧钱预测 (当月)', style: GoogleFonts.plusJakartaSans(fontSize: 14, fontWeight: FontWeight.bold, color: iconColor)),
                    const SizedBox(height: 6),
                    Text(predictionText, style: GoogleFonts.plusJakartaSans(fontSize: 13, height: 1.5, color: const Color(0xFF37474F))),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class SubscriptionRadarCard extends StatelessWidget {
  const SubscriptionRadarCard({required this.book, super.key});
  final LedgerBook book;

  @override
  Widget build(BuildContext context) {
    final now = DateTime.now();
    
    // Group expenses by merchant and amount to identify subscriptions automatically!
    final map = <String, List<LedgerEntry>>{};
    
    for (final e in book.entries) {
      if (e.type != EntryType.expense) continue;
      // Consider transactions within the last 4 months
      if (now.difference(e.occurredAt).inDays > 120) continue;
      
      final key = "${e.merchant}_${e.amount.toStringAsFixed(2)}_${e.occurredAt.day}";
      if (!map.containsKey(key)) {
        map[key] = [];
      }
      map[key]!.add(e);
    }

    final upcomingList = <String>[];
    
    for (final key in map.keys) {
      final occurrences = map[key]!;
      if (occurrences.length >= 2) {
        // Repeated at least twice
        final targetDay = occurrences.first.occurredAt.day;
        final amount = occurrences.first.amount;
        final merchant = occurrences.first.merchant;
        
        // Find if it occurs this month or soon.
        // We warn if targetDay is within 1 to 5 days ahead of now.day.
        int diff = targetDay - now.day;
        if (diff < 0) {
           int daysInMonth = DateTime(now.year, now.month + 1, 0).day;
           diff = targetDay + (daysInMonth - now.day);
        }
        
        if (diff > 0 && diff <= 5) {
          // Check if already paid this month
          bool alreadyPaid = occurrences.any((e) => e.occurredAt.year == now.year && e.occurredAt.month == now.month && e.occurredAt.day == targetDay);
          if (!alreadyPaid) {
            final descMerchant = merchant.isEmpty ? "固定自动扣款" : merchant;
            // Prevent duplicate entries
            final msg = "您极有可能在 ${diff} 天后 (大概${targetDay}号) 遭遇 [ $descMerchant ] 的连续扣费自动出账 ￥${amount.toStringAsFixed(2)}。";
            if (!upcomingList.contains(msg)) upcomingList.add(msg);
          }
        }
      }
    }

    if (upcomingList.isEmpty) return const SizedBox.shrink();

    return Padding(
      padding: const EdgeInsets.only(bottom: 16.0),
      child: _IntelliCard(
        color: const Color(0xFFFFF0F5),
        child: Padding(
          padding: const EdgeInsets.all(16.0),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const Icon(Icons.radar, color: Color(0xFFD81B60), size: 28),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text('订阅防刺客雷达', style: GoogleFonts.plusJakartaSans(fontSize: 14, fontWeight: FontWeight.bold, color: const Color(0xFFD81B60))),
                    const SizedBox(height: 6),
                    ...upcomingList.map((t) => Padding(
                      padding: const EdgeInsets.only(top: 4.0),
                      child: Text('\u26a0\ufe0f $t', style: GoogleFonts.plusJakartaSans(fontSize: 13, height: 1.5, color: const Color(0xFF424242))),
                    )).toList(),
                    const SizedBox(height: 6),
                    Text('请确认服务是否需要，防患于未然！', style: GoogleFonts.plusJakartaSans(fontSize: 12, fontWeight: FontWeight.w600, color: const Color(0xFFC2185B))),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class MoodConsumptionChartCard extends StatelessWidget {
  const MoodConsumptionChartCard({required this.book, super.key});
  final LedgerBook book;

  @override
  Widget build(BuildContext context) {
    final now = DateTime.now();
    
    // Get current month expense
    final currentMonthExpenses = book.entries.where((e) => 
      e.type == EntryType.expense &&
      e.occurredAt.year == now.year &&
      e.occurredAt.month == now.month &&
      e.mood != ExpenseMood.none
    ).toList();

    if (currentMonthExpenses.isEmpty) return const SizedBox.shrink();

    double totalWithMood = 0;
    final Map<ExpenseMood, double> moodTotals = {};
    for (final e in currentMonthExpenses) {
      totalWithMood += e.amount;
      moodTotals[e.mood] = (moodTotals[e.mood] ?? 0) + e.amount;
    }

    // Find the max mood
    ExpenseMood topMood = ExpenseMood.none;
    double maxAmount = 0;
    moodTotals.forEach((mood, amount) {
      if (amount > maxAmount) {
        maxAmount = amount;
        topMood = mood;
      }
    });

    if (maxAmount == 0 || topMood == ExpenseMood.none) return const SizedBox.shrink();

    final percentage = (maxAmount / totalWithMood * 100).toStringAsFixed(0);
    
    String insightMsgText = "";
    if (topMood == ExpenseMood.tired) {
      insightMsgText = "这说明本月有一波因为持续劳累/加班而导致的情绪代偿消费，记得好好心疼自己哦~☕";
    } else if (topMood == ExpenseMood.happy) {
      insightMsgText = "好棒的感觉！本月您有不少为了开心庆祝而买单的快乐投资，希望您每天都如今天般灿烂！🎉";
    } else if (topMood == ExpenseMood.angry) {
      insightMsgText = "哎呀，本月您有一笔不小的支出是因为冲动或解压，破财免灾，下次呼吸深一点哦~😡";
    } else if (topMood == ExpenseMood.sad) {
      insightMsgText = "也许这个月发生了一些不愉快，希望用那些消费买来的抚慰能让您好受一点，抱抱你~🌧️";
    } else if (topMood == ExpenseMood.chill) {
      insightMsgText = "非常棒的状态！您在平静理智中进行的消费，一切尽在掌握中，继续保持！🧘";
    }

    return Padding(
      padding: const EdgeInsets.only(bottom: 16.0),
      child: _IntelliCard(
        color: topMood.color.withValues(alpha: 0.1),
        child: Padding(
          padding: const EdgeInsets.all(16.0),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  Icon(Icons.favorite, color: topMood.color, size: 28),
                  const SizedBox(width: 12),
                  Text('情绪消费图谱 (当月)', style: GoogleFonts.plusJakartaSans(fontSize: 15, fontWeight: FontWeight.bold, color: topMood.color)),
                ],
              ),
              const SizedBox(height: 12),
              // Simple bar view percentage
              ClipRRect(
                borderRadius: BorderRadius.circular(8),
                child: Container(
                  height: 12,
                  width: double.infinity,
                  color: topMood.color.withValues(alpha: 0.2),
                  alignment: Alignment.centerLeft,
                  child: FractionallySizedBox(
                    widthFactor: maxAmount / totalWithMood,
                    child: Container(
                      decoration: BoxDecoration(
                        color: topMood.color,
                        borderRadius: BorderRadius.circular(8),
                      ),
                    ),
                  ),
                ),
              ),
              const SizedBox(height: 12),
              Text(
                "本月您投入了 $percentage% (￥${maxAmount.toStringAsFixed(2)}) 在【${topMood.label}${topMood.emoji}】的情境下！",
                style: GoogleFonts.plusJakartaSans(fontSize: 14, fontWeight: FontWeight.bold, color: const Color(0xFF37474F)),
              ),
              const SizedBox(height: 6),
              Text(
                insightMsgText,
                style: GoogleFonts.plusJakartaSans(fontSize: 13, height: 1.5, color: const Color(0xFF546E7A)),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
