part of 'app.dart';

class NlpExtractionResult {
  final double? amount;
  final DateTime? date;
  final String merchant;
  final String item;
  final String? categoryId;

  NlpExtractionResult({
    this.amount,
    this.date,
    this.merchant = '',
    this.item = '',
    this.categoryId,
  });

  bool get isComplete => amount != null;
}

class NlpParser {
  NlpParser._();

  static NlpExtractionResult parse(String text) {
    if (text.trim().isEmpty) return NlpExtractionResult();

    double? amount;
    DateTime? date;
    String merchant = '';
    String item = '';
    String? categoryId;

    // 1. Extract Amount
    // Regex matches: "花了5.5块", "¥20", "20元", "300.5"
    final amountRegex = RegExp(r'(?:花了|用了|一共|大概)?(?:¥|\$)?\s*([0-9]+(?:\.[0-9]+)?)\s*(?:块钱?|元|个W)?');
    final amountMatch = amountRegex.firstMatch(text);
    if (amountMatch != null) {
      amount = double.tryParse(amountMatch.group(1) ?? '');
    } else {
      // Fallback: look for ANY number
      final fallbackAmount = RegExp(r'([0-9]+\.[0-9]+|[0-9]+)').firstMatch(text);
      if (fallbackAmount != null) {
        amount = double.tryParse(fallbackAmount.group(1) ?? '');
      }
    }

    // 2. Extract Date Time
    final now = DateTime.now();
    date = now; // Default is right now
    if (text.contains('前天')) {
      date = now.subtract(const Duration(days: 2));
    } else if (text.contains('昨天') || text.contains('昨晚')) {
      date = now.subtract(const Duration(days: 1));
    } else if (text.contains('刚才') || text.contains('今天')) {
      date = now;
    }
    
    // Fine-tune time
    if (text.contains('早上') || text.contains('早晨')) {
      date = DateTime(date.year, date.month, date.day, 8, 0);
    } else if (text.contains('中午')) {
      date = DateTime(date.year, date.month, date.day, 12, 0);
    } else if (text.contains('下午')) {
      date = DateTime(date.year, date.month, date.day, 16, 0);
    } else if (text.contains('晚上') || text.contains('昨晚')) {
      date = DateTime(date.year, date.month, date.day, 20, 0);
    }

    // 3. Extract Merchant & Item (Heuristic rules)
    // Rule A: "在 [merchant] 买/吃/点 [item] 花了"
    final ruleA = RegExp(r'在(.*)(买|吃|点)(.*)(?:花了|用了|大概|¥)');
    final matchA = ruleA.firstMatch(text);
    if (matchA != null) {
      merchant = matchA.group(1)?.trim() ?? '';
      item = matchA.group(3)?.trim() ?? '';
    } else {
      // Rule B: "去 [merchant] 买 [item]"
      final ruleB = RegExp(r'(?:去|给)(.*)(买|吃|点|加)(.*)(?:花了|用了|大概|¥)');
      final matchB = ruleB.firstMatch(text);
      if (matchB != null) {
        merchant = matchB.group(1)?.trim() ?? '';
        item = matchB.group(3)?.trim() ?? '';
      } else {
        // Fallback: Just grab something near keywords
        final kwBuy = RegExp(r'(?:买|吃|点|打车去)(.*)(?:花了|用了|大概|¥)');
        final matchKW = kwBuy.firstMatch(text);
        if (matchKW != null) item = matchKW.group(1)?.trim() ?? '';
      }
    }
    
    // Clean up particles
    merchant = merchant.replaceFirst(RegExp(r'^(了)'), '').trim();
    item = item.replaceFirst(RegExp(r'^(了)'), '').trim();

    // 4. Guess Category based on keywords
    final fullContext = text.toLowerCase();
    if (fullContext.contains('吃') || fullContext.contains('水') || fullContext.contains('拿铁') || fullContext.contains('咖啡') || fullContext.contains('零食') || fullContext.contains('早餐') || fullContext.contains('饭')) {
      categoryId = 'food';
    } else if (fullContext.contains('打车') || fullContext.contains('油') || fullContext.contains('地铁') || fullContext.contains('公交')) {
      categoryId = 'mobility';
    } else if (fullContext.contains('买衣服') || fullContext.contains('淘宝') || fullContext.contains('购物')) {
      categoryId = 'shopping';
    } else if (fullContext.contains('电影') || fullContext.contains('唱歌') || fullContext.contains('玩')) {
      categoryId = 'entertainment';
    }

    // Use full text as item fallback if empty
    if (item.isEmpty && merchant.isEmpty) {
      // Clean string from numbers
      item = text.replaceAll(amountRegex, '').replaceAll(RegExp(r'(昨天|今天|前天|早上|晚上|刚才)'), '').trim();
    }

    return NlpExtractionResult(
      amount: amount,
      date: date,
      merchant: merchant,
      item: item,
      categoryId: categoryId,
    );
  }
}
