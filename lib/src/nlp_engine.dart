part of 'app.dart';

class NlpExtractionResult {
  final double? amount;
  final DateTime? date;
  final String merchant;
  final String item;
  final String? categoryId;
  final bool isIncome;

  NlpExtractionResult({
    this.amount,
    this.date,
    this.merchant = '',
    this.item = '',
    this.categoryId,
    this.isIncome = false,
  });

  bool get isComplete => amount != null;
}

class NlpParser {
  NlpParser._();

  // ── Known merchants (name → category) ──
  static const _knownMerchants = <String, String>{
    '星巴克': 'food', '瑞幸': 'food', '喜茶': 'food', '奈雪': 'food',
    '蜜雪冰城': 'food', '茶百道': 'food', '古茗': 'food', '益禾堂': 'food',
    '肯德基': 'food', '麦当劳': 'food', '必胜客': 'food', '华莱士': 'food',
    '海底捞': 'food', '西贝': 'food', '呷哺呷哺': 'food', '大董': 'food',
    '德克士': 'food', '汉堡王': 'food', '烤匠': 'food',
    '全家': 'food', '罗森': 'food', '711': 'food', '便利蜂': 'food',
    '美团': 'food', '饿了么': 'food',
    '淘宝': 'shopping', '天猫': 'shopping', '京东': 'shopping',
    '拼多多': 'shopping', '闲鱼': 'shopping', '唯品会': 'shopping',
    '抖音': 'shopping', '快手': 'shopping',  '小红书': 'shopping',
    '沃尔玛': 'shopping', '家乐福': 'shopping', '永辉': 'shopping',
    '盒马': 'food', '叮咚买菜': 'food', '朴朴': 'food',
    '滴滴': 'mobility', '高德': 'mobility', 'T3': 'mobility',
    '曹操': 'mobility', '哈啰': 'mobility', '青桔': 'mobility',
    '中国石油': 'mobility', '中国石化': 'mobility', '壳牌': 'mobility',
    '万达': 'entertainment', 'CGV': 'entertainment',
    '大众点评': 'food', '口碑': 'food',
    '网易云': 'entertainment', 'QQ音乐': 'entertainment',
    '爱奇艺': 'entertainment', '优酷': 'entertainment', '腾讯视频': 'entertainment',
    'bilibili': 'entertainment', 'B站': 'entertainment',
  };

  // ── Amount extraction patterns (ordered by specificity) ──
  static final _amountPatterns = [
    // "花了35.5块" / "用了20元" / "一共100" / "花费50"
    RegExp(r'(?:花了|花费|用了|一共|总共|总计|合计|大概|约|共)\s*(?:¥|￥)?\s*([0-9]+(?:\.[0-9]+)?)\s*(?:块钱?|元|圆)?'),
    // "¥35.5" / "￥100"
    RegExp(r'(?:¥|￥)\s*([0-9]+(?:\.[0-9]+)?)'),
    // "35块" / "20元" / "100块钱"
    RegExp(r'([0-9]+(?:\.[0-9]+)?)\s*(?:块钱?|元|圆)'),
    // "收入500" / "工资8000" / "收了200"
    RegExp(r'(?:收入|工资|薪资|薪水|收了|赚了|进账|到账|入账|退款|报销|红包)\s*(?:¥|￥)?\s*([0-9]+(?:\.[0-9]+)?)'),
    // Bare number anywhere in the text: "午饭35" / "打车15" / "咖啡28.5"
    RegExp(r'([0-9]+(?:\.[0-9]+)?)'),
  ];

  // ── Income signal words ──
  static const _incomeSignals = [
    '收入', '工资', '薪资', '薪水', '奖金', '绩效', '收了', '赚了', '赚到',
    '进账', '到账', '入账', '转入', '退款', '报销', '红包', '收款',
    '利息', '分红', '补贴', '津贴', '回款',
  ];

  // ── Date patterns ──
  static final _datePatterns = <String, int Function(DateTime)>{
    '大前天': (now) => -3,
    '前天': (now) => -2,
    '昨天': (now) => -1,
    '昨晚': (now) => -1,
    '今天': (now) => 0,
    '刚才': (now) => 0,
    '今早': (now) => 0,
    '今晚': (now) => 0,
  };

  static final _timeHints = {
    '早上': 8, '早晨': 8, '上午': 10, '今早': 8,
    '中午': 12, '午饭': 12, '午餐': 12,
    '下午': 15,
    '傍晚': 18, '晚饭': 18, '晚餐': 18,
    '晚上': 20, '今晚': 20, '昨晚': 20, '宵夜': 22,
  };

  // ── Category mapping (keyword → categoryId) ──
  static const _categoryMap = <String, List<String>>{
    'food': ['吃', '饭', '餐', '面', '粉', '粥', '菜', '火锅', '烧烤', '串', '奶茶', '咖啡', '拿铁',
             '水果', '零食', '小吃', '外卖', '食堂', '早餐', '午餐', '晚餐', '宵夜',
             '蛋糕', '面包', '饮料', '果汁', '茶', '酒', '啤酒', '可乐', '矿泉水', '牛奶', '酸奶',
             '包子', '饺子', '馒头', '豆浆', '鸡蛋', '水', '雪糕', '冰淇淋'],
    'mobility': ['打车', '滴滴', '出租', '地铁', '公交', '高铁', '火车', '飞机', '机票', '加油', '油费',
                 '停车', '过路费', '高速', '骑车', '共享单车', '汽车', '导航'],
    'shopping': ['购物', '买衣服', '买鞋', '超市', '商场', '买东西', '网购', '直播', '下单'],
    'entertainment': ['电影', '唱歌', 'ktv', '游戏', '充值', '会员', 'vip', '视频',
                      '音乐', '演出', '门票', '旅游', '景点'],
    'housing': ['房租', '水费', '电费', '燃气', '物业', '宽带', '网费', '话费', '充话费'],
    'health': ['医院', '药', '看病', '挂号', '体检', '疫苗', '牙', '眼镜', '配眼镜'],
    'education': ['学费', '培训', '课程', '书', '教材', '考试', '报名', '辅导'],
    'salary': ['工资', '薪资', '薪水', '奖金', '绩效', '分红', '利息', '补贴', '津贴',
               '收入', '进账', '到账', '入账', '转入', '退款', '报销', '红包', '收款', '回款',
               '赚了', '赚到', '收了'],
  };

  // ── Merchant extraction patterns ──
  static final _merchantPatterns = [
    // "在XX买/吃/喝/点/消费"
    RegExp(r'[在去到]([^\d¥￥,，。\s]{2,10}?)(?:买|吃|喝|点|消费|花|用|充|加|打|坐|逛|看)'),
    // "XX的/家"
    RegExp(r'([^\d¥￥,，。\s]{2,8}?)(?:的|家|店|那|那里|那边)'),
  ];

  // ── Item extraction patterns ──
  static final _itemPatterns = [
    // "买了XX" / "吃了XX" / "点了XX" / "喝了XX"
    RegExp(r'(?:买了?|吃了?|喝了?|点了?|充了?|加了?|坐了?|打了?|看了?)([^\d¥￥]{1,12}?)(?:花了|用了|一共|总共|大概|约|共|$|\d|¥|￥|块|元)'),
    // "XX花了..."
    RegExp(r'^([^\d¥￥]{2,10}?)(?:\d|花了|用了|一共)'),
  ];

  // ── Chinese numeral map ──
  static const _cnDigits = {
    '零': 0, '〇': 0,
    '一': 1, '壹': 1,
    '二': 2, '贰': 2, '两': 2, '俩': 2,
    '三': 3, '叁': 3,
    '四': 4, '肆': 4,
    '五': 5, '伍': 5,
    '六': 6, '陆': 6,
    '七': 7, '柒': 7,
    '八': 8, '捌': 8,
    '九': 9, '玖': 9,
    '十': 10, '拾': 10,
    '百': 100, '佰': 100,
    '千': 1000, '仟': 1000,
    '万': 10000, '萬': 10000,
  };

  /// Convert Chinese numeral string to double.
  static double? _chineseToNumber(String s) {
    if (s.isEmpty) return null;

    // Handle 点 as decimal
    final dotIdx = s.indexOf('点');
    if (dotIdx >= 0) {
      final intPart = dotIdx > 0 ? _chineseToNumber(s.substring(0, dotIdx)) : 0;
      if (intPart == null) return null;
      final fracStr = s.substring(dotIdx + 1);
      double frac = 0;
      double place = 0.1;
      for (final c in fracStr.runes.map((r) => String.fromCharCode(r))) {
        final d = _cnDigits[c];
        if (d == null || d >= 10) return null;
        frac += d * place;
        place *= 0.1;
      }
      return intPart + frac;
    }

    int result = 0;
    int current = 0;

    for (final c in s.runes.map((r) => String.fromCharCode(r))) {
      final val = _cnDigits[c];
      if (val == null) return null;

      if (val == 10000) {
        if (current == 0) current = 1;
        result = (result + current) * 10000;
        current = 0;
      } else if (val == 1000) {
        if (current == 0) current = 1;
        current *= 1000;
      } else if (val == 100) {
        if (current == 0) current = 1;
        current *= 100;
      } else if (val == 10) {
        if (current == 0) current = 1;
        current *= 10;
      } else {
        current = current + val;
      }
    }
    result += current;
    return result > 0 ? result.toDouble() : null;
  }

  static final _cnNumPattern = RegExp(r'[零〇一壹二贰两俩三叁四肆五伍六陆七柒八捌九玖十拾百佰千仟万萬点]+');

  /// Pre-process Step 1: Chinese numerals → Arabic
  static String _normalizeCnNumbers(String input) {
    return input.replaceAllMapped(_cnNumPattern, (match) {
      final cn = match.group(0)!;
      final num = _chineseToNumber(cn);
      if (num == null) return cn;
      if (num == num.truncateToDouble()) {
        return num.toInt().toString();
      }
      return num.toStringAsFixed(2);
    });
  }

  /// Pre-process Step 2: "3块5" → "3.5", "3点5" → "3.5", "10块5毛" → "10.5"
  static String _normalizeColloquialAmount(String input) {
    // "X块Y" / "X块Y毛" → "X.Y"
    var result = input.replaceAllMapped(
      RegExp(r'(\d+)\s*块\s*(\d)\s*(?:毛|角)?'),
      (m) => '${m.group(1)}.${m.group(2)}元',
    );
    // "X点Y" (when Y is a single digit after 点, treat as decimal)
    result = result.replaceAllMapped(
      RegExp(r'(\d+)\s*点\s*(\d+)'),
      (m) => '${m.group(1)}.${m.group(2)}',
    );
    // "X毛" alone → "0.X"
    result = result.replaceAllMapped(
      RegExp(r'(?<!\d)(\d)\s*毛'),
      (m) => '0.${m.group(1)}元',
    );
    return result;
  }

  static NlpExtractionResult parse(String text) {
    if (text.trim().isEmpty) return NlpExtractionResult();

    // Pre-process pipeline
    var input = text.trim();
    input = _normalizeCnNumbers(input);       // 三十五 → 35
    input = _normalizeColloquialAmount(input); // 3块5 → 3.5元, 3点5 → 3.5

    // ─── 1. Amount ───
    double? amount;
    String amountMatchStr = '';

    // First, try specific patterns (with context)
    for (var i = 0; i < _amountPatterns.length - 1; i++) {
      final match = _amountPatterns[i].firstMatch(input);
      if (match != null) {
        final parsed = double.tryParse(match.group(1) ?? '');
        if (parsed != null && parsed > 0 && parsed < 10000000) {
          amount = parsed;
          amountMatchStr = match.group(0) ?? '';
          break;
        }
      }
    }

    // Fallback: bare number — skip date/time numbers
    if (amount == null) {
      final barePattern = _amountPatterns.last;
      for (final match in barePattern.allMatches(input)) {
        final numStr = match.group(1) ?? '';
        final parsed = double.tryParse(numStr);
        if (parsed == null || parsed <= 0 || parsed >= 10000000) continue;

        final afterIdx = match.end;
        if (afterIdx < input.length) {
          final nextChar = input[afterIdx];
          if ('号日月年时分秒'.contains(nextChar)) continue;
        }

        amount = parsed;
        amountMatchStr = match.group(0) ?? '';
        break;
      }
    }

    // ─── 2. Income vs Expense ───
    bool isIncome = false;
    for (final signal in _incomeSignals) {
      if (input.contains(signal)) {
        isIncome = true;
        break;
      }
    }

    // ─── 3. Date ───
    final now = DateTime.now();
    DateTime date = now;
    for (final entry in _datePatterns.entries) {
      if (input.contains(entry.key)) {
        final offset = entry.value(now);
        date = now.add(Duration(days: offset));
        break;
      }
    }
    final dayMatch = RegExp(r'(\d{1,2})[号日]').firstMatch(input);
    if (dayMatch != null) {
      final day = int.tryParse(dayMatch.group(1) ?? '') ?? 0;
      if (day >= 1 && day <= 31) {
        date = DateTime(date.year, date.month, day);
      }
    }
    for (final entry in _timeHints.entries) {
      if (input.contains(entry.key)) {
        date = DateTime(date.year, date.month, date.day, entry.value);
        break;
      }
    }

    // ─── 4. Known Merchant (priority: exact name match in text) ───
    String merchant = '';
    String? merchantCategory;
    for (final entry in _knownMerchants.entries) {
      if (input.contains(entry.key)) {
        merchant = entry.key;
        merchantCategory = entry.value;
        break;
      }
    }

    // ─── 5. Regex Merchant (fallback if no known merchant) ───
    if (merchant.isEmpty) {
      for (final pattern in _merchantPatterns) {
        final match = pattern.firstMatch(input);
        if (match != null) {
          final candidate = _cleanToken(match.group(1) ?? '');
          if (candidate.length >= 2 && !_isNoiseWord(candidate)) {
            merchant = candidate;
            break;
          }
        }
      }
    }

    // ─── 6. Item ───
    String item = '';
    for (final pattern in _itemPatterns) {
      final match = pattern.firstMatch(input);
      if (match != null) {
        final candidate = _cleanToken(match.group(1) ?? '');
        if (candidate.isNotEmpty && candidate != merchant && !_isNoiseWord(candidate)) {
          item = candidate;
          break;
        }
      }
    }

    // ─── 7. Smart fallback title ───
    if (item.isEmpty && amount != null) {
      String cleaned = input;
      if (amountMatchStr.isNotEmpty) {
        cleaned = cleaned.replaceAll(amountMatchStr, '');
      }
      cleaned = cleaned.replaceAll(RegExp(r'[0-9]+(?:\.[0-9]+)?'), '');
      cleaned = cleaned.replaceAll(RegExp(r'[¥￥$]'), '');
      for (final w in ['花了', '用了', '一共', '总共', '大概', '约', '块钱', '块', '元', '圆',
                        '昨天', '今天', '前天', '大前天', '刚才', '早上', '中午', '下午', '晚上',
                        '收入', '工资', '收了', '赚了', '在', '去', '到', '了', '的',
                        '买', '吃', '喝', '点', '给']) {
        cleaned = cleaned.replaceAll(w, '');
      }
      cleaned = cleaned.replaceAll(RegExp(r'\s+'), ' ').trim();
      // Don't use single-char garbage as item; and don't duplicate merchant
      if (cleaned.isNotEmpty && cleaned.length <= 15 && cleaned != merchant) {
        item = cleaned;
      }
    }

    // ─── 8. Category ───
    String? categoryId = merchantCategory; // Priority: known merchant's category
    if (categoryId == null) {
      final ctx = input.toLowerCase();
      for (final entry in _categoryMap.entries) {
        for (final kw in entry.value) {
          if (ctx.contains(kw)) {
            categoryId = entry.key;
            break;
          }
        }
        if (categoryId != null) break;
      }
    }

    return NlpExtractionResult(
      amount: amount,
      date: date,
      merchant: merchant,
      item: item,
      categoryId: categoryId,
      isIncome: isIncome,
    );
  }

  static String _cleanToken(String s) {
    return s.replaceAll(RegExp(r'^[了的在去到给]'), '')
            .replaceAll(RegExp(r'[了的]$'), '')
            .trim();
  }

  static bool _isNoiseWord(String s) {
    const noise = {'我', '他', '她', '它', '你', '一个', '一些', '一下', '那个', '这个',
                   '东西', '什么', '多少', '花了', '用了', '昨天', '今天', '前天', '刚才'};
    return noise.contains(s);
  }
}
