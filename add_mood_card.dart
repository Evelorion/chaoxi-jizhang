import 'dart:io';

void main() async {
  final file = File('lib/src/ui_predict_cards.dart');
  var text = await file.readAsString();

  final moodCardCode = '''

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
                "本月您投入了 \$percentage% (￥\${maxAmount.toStringAsFixed(2)}) 在【\${topMood.label}\${topMood.emoji}】的情境下！",
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
''';

  await file.writeAsString(text + moodCardCode);
  print('Added MoodConsumptionChartCard to ui_predict_cards.dart');
}
