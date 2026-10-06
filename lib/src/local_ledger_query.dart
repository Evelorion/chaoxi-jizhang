part of 'app.dart';

/// 用户问题被翻译成的结构化查询条件。
/// 模型只干这一件事：自然语言 → 这个对象；求和、排序、统计全在本地做。
class LedgerQuerySpec {
  const LedgerQuerySpec({
    this.continueContext = false,
    this.intent = 'sum',
    this.merchant,
    this.categoryId,
    this.channel,
    this.startDate,
    this.endDate,
    this.limit,
    this.amount,
  });

  /// true 表示接着上一句问，未填的字段沿用上一轮。
  final bool continueContext;
  final String intent;
  final String? merchant;
  final String? categoryId;
  final String? channel;
  final DateTime? startDate;
  final DateTime? endDate;
  final int? limit;

  /// 用户记得金额时（"我有个78的消费记录吗"），按金额精确找。
  final double? amount;

  static const intents = {
    'sum',
    'count',
    'average',
    'compare',
    'top_merchant',
    'top_category',
    'latest',
    'monthly_summary',
    'find',
    'fuzzy',
  };

  /// 沿用上一轮：新条件下为空的字段从上一轮继承，填了的覆盖。
  LedgerQuerySpec mergedWith(LedgerQuerySpec? previous) {
    if (!continueContext || previous == null) return this;
    return LedgerQuerySpec(
      continueContext: false,
      intent: intent.isEmpty ? previous.intent : intent,
      merchant: merchant ?? previous.merchant,
      categoryId: categoryId ?? previous.categoryId,
      channel: channel ?? previous.channel,
      startDate: startDate ?? previous.startDate,
      endDate: endDate ?? previous.endDate,
      limit: limit ?? previous.limit,
      amount: amount ?? previous.amount,
    );
  }

  Map<String, dynamic> toJson() => {
    'intent': intent,
    'merchant': merchant,
    'category': categoryId,
    'channel': channel,
    'start_date': startDate == null
        ? null
        : _compactDateFormatter.format(startDate!),
    'end_date': endDate == null ? null : _compactDateFormatter.format(endDate!),
    if (amount != null) 'amount': amount,
  };

  @override
  String toString() => jsonEncode(toJson());
}

/// 解析模型的输出。只接受合法的 intent，其余一律返回 null 交给兜底逻辑。
LedgerQuerySpec? parseLedgerQuerySpec(String raw, {DateTime? now}) {
  final begin = raw.indexOf('{');
  final end = raw.lastIndexOf('}');
  if (begin < 0 || end <= begin) return null;
  try {
    final decoded = jsonDecode(raw.substring(begin, end + 1));
    if (decoded is! Map) return null;
    final intent = (decoded['intent'] as String?)?.trim() ?? '';
    if (!LedgerQuerySpec.intents.contains(intent)) return null;
    final categoryText = (decoded['category'] as String?)?.trim() ?? '';
    final merchantText = (decoded['merchant'] as String?)?.trim() ?? '';
    final channelText = (decoded['channel'] as String?)?.trim() ?? '';
    return LedgerQuerySpec(
      continueContext: decoded['continue_context'] == true,
      intent: intent,
      merchant: merchantText.isEmpty ? null : merchantText,
      categoryId: _categoryIdFromText(categoryText),
      channel: channelText.isEmpty ? null : channelText,
      startDate: _parseSpecDate(decoded['start_date']),
      endDate: _parseSpecDate(decoded['end_date']),
      limit: (decoded['limit'] as num?)?.toInt(),
      amount: (decoded['amount'] as num?)?.toDouble(),
    );
  } on FormatException {
    return null;
  }
}

/// 模型可能写"餐饮"这样的中文分类名，转成应用内部的分类 ID。
String? _categoryIdFromText(String text) {
  if (text.isEmpty) return null;
  final normalized = text.replaceAll(RegExp(r'[\s分类]'), '');
  for (final category in appCategories) {
    if (category.id == normalized) return category.id;
    if (category.name == normalized) return category.id;
  }
  for (final category in appCategories) {
    if (normalized.contains(category.name)) return category.id;
  }
  return null;
}

DateTime? _parseSpecDate(Object? value) {
  if (value is! String || value.trim().isEmpty) return null;
  final text = value.trim().replaceAll('/', '-').replaceAll('.', '-');
  final parsed = DateTime.tryParse(text);
  if (parsed != null) return DateTime(parsed.year, parsed.month, parsed.day);
  final month = RegExp(r'^(\d{4})-(\d{1,2})$').firstMatch(text);
  if (month != null) {
    return DateTime(int.parse(month.group(1)!), int.parse(month.group(2)!), 1);
  }
  return null;
}

/// 常见中文问法的**规则解析**：这些句子不该劳烦模型，本地一眼就能看懂。
/// 返回 null 表示"不敢确定"，交给模型去翻译（模型也失败时会走模糊检索或如实说没听懂）。
///
/// 覆盖：今天/昨天/前天/本周/上周/本月/上个月/今年/去年/最近N天/最近、
/// 花了多少/几笔/平均/最多/最近一笔/有没有/找/对比/汇总/什么时间，
/// 以及分类名、渠道、商户名、金额。
LedgerQuerySpec? parseLedgerQuerySpecByRules(
  String question, {
  DateTime? now,
  LedgerBook? book,
}) {
  final text = question.trim();
  if (text.isEmpty) return null;
  final anchor = now ?? DateTime.now();
  final today = DateTime(anchor.year, anchor.month, anchor.day);

  // ---- 时间 ----
  DateTime? start;
  DateTime? end;
  void day(DateTime value) {
    start = value;
    end = value;
  }

  bool has(String word) => text.contains(word);
  final lastDays = RegExp(r'最近\s*(\d{1,3})\s*天').firstMatch(text);
  if (has('今天') || has('今日')) {
    day(today);
  } else if (has('昨天') || has('昨日')) {
    day(today.subtract(const Duration(days: 1)));
  } else if (has('前天')) {
    day(today.subtract(const Duration(days: 2)));
  } else if (has('上周')) {
    final monday = today.subtract(Duration(days: today.weekday - 1));
    start = monday.subtract(const Duration(days: 7));
    end = monday.subtract(const Duration(days: 1));
  } else if (has('本周') || has('这周') || has('这个星期')) {
    start = today.subtract(Duration(days: today.weekday - 1));
    end = today;
  } else if (has('上个月') || has('上月')) {
    start = DateTime(today.year, today.month - 1, 1);
    end = DateTime(today.year, today.month, 0);
  } else if (has('这个月') || has('本月') || has('这月')) {
    start = DateTime(today.year, today.month, 1);
    end = DateTime(today.year, today.month + 1, 0);
  } else if (has('今年') || has('本年')) {
    start = DateTime(today.year, 1, 1);
    end = today;
  } else if (has('去年')) {
    start = DateTime(today.year - 1, 1, 1);
    end = DateTime(today.year - 1, 12, 31);
  } else if (lastDays != null) {
    final days = int.parse(lastDays.group(1)!);
    start = today.subtract(Duration(days: days - 1));
    end = today;
  } else if (has('最近') || has('这几天') || has('近期')) {
    start = today.subtract(const Duration(days: 29));
    end = today;
  }

  // ---- 金额（只在"找某笔"的语气里当金额，避免把日期数字当钱）----
  double? amount;
  final amountMatch = RegExp(
    r'(\d{1,6}(?:\.\d{1,2})?)\s*(?:元|块|块钱|rmb|￥|¥)?',
  ).firstMatch(text.replaceAll(RegExp(r'最近\s*\d{1,3}\s*天'), ' '));
  final lookupTone =
      has('有没有') || has('有吗') || has('找') || has('记录') || has('哪笔') ||
      has('哪一笔') || has('查') || has('是不是') || has('记得');
  if (amountMatch != null) {
    final hasMoneyUnit = RegExp(
      r'\d{1,6}(?:\.\d{1,2})?\s*(?:元|块|块钱|rmb|￥|¥)',
    ).hasMatch(text);
    if (hasMoneyUnit || lookupTone) {
      amount = double.tryParse(amountMatch.group(1)!);
    }
  }

  // ---- 意图 ----
  String? intent;
  if (has('什么时间') ||
      has('什么时候') ||
      has('哪天') ||
      has('多久') ||
      has('时间')) {
    intent = 'latest';
  } else if (has('几笔') || has('多少笔') || has('笔数')) {
    intent = 'count';
  } else if (has('平均')) {
    intent = 'average';
  } else if (has('最多') || has('排行') || has('花得最')) {
    intent = has('商户') || has('商家') || has('店') ? 'top_merchant' : 'top_category';
  } else if (has('最近一笔') ||
      has('最后一笔') ||
      has('上一笔') ||
      has('最近一次')) {
    intent = 'latest';
  } else if (has('对比') || has('比上个月') || has('比上月') || has('变化')) {
    intent = 'compare';
  } else if (has('汇总') || has('总结') || has('情况') || has('概览')) {
    intent = 'monthly_summary';
  } else if (has('有没有') ||
      has('有吗') ||
      has('找') ||
      has('记录') ||
      has('哪笔') ||
      has('哪一笔') ||
      has('查') ||
      has('什么消费') ||
      has('有哪些') ||
      has('有什么')) {
    intent = 'find';
  } else if (has('花了多少') ||
      has('花了多少钱') ||
      has('多少钱') ||
      has('消费多少') ||
      has('支出多少') ||
      has('花了') ||
      has('花费') ||
      has('开销')) {
    intent = 'sum';
  }

  // ---- 分类 / 渠道 / 商户 ----
  String? categoryId;
  for (final category in appCategories) {
    if (text.contains(category.name)) {
      categoryId = category.id;
      break;
    }
  }
  String? channel;
  for (final candidate in ['微信', '支付宝', '银行卡', '现金', '云闪付']) {
    if (text.contains(candidate)) {
      channel = candidate;
      break;
    }
  }
  String? merchant;
  if (book != null) {
    final names = <String>{
      ...book.merchantCategories.keys,
      for (final entry in book.entries.take(400))
        if (entry.merchant.trim().isNotEmpty &&
            entry.merchant.trim() != '未识别商户')
          entry.merchant.trim(),
    };
    // 取最长的匹配，避免"麦当劳"被"麦当劳成都店"抢先
    for (final name in names.toList()..sort((a, b) => b.length.compareTo(a.length))) {
      if (name.length >= 2 && text.contains(name)) {
        merchant = name;
        break;
      }
    }
  }

  // 追问："那交通呢""上个月呢""什么时间" —— 继承上一轮
  final isFollowUp = has('那') ||
      has('呢') ||
      (intent == 'latest' && merchant == null && categoryId == null && amount == null);
  final continueContext =
      isFollowUp &&
      intent != null &&
      (intent == 'latest' ||
          intent == 'sum' ||
          intent == 'count' ||
          intent == 'find' ||
          intent == 'average');

  // 什么都没认出来 → 交给模型
  if (intent == null && start == null && categoryId == null && amount == null) {
    return null;
  }
  // 只有时间没有意图（"最近"这种）→ 不敢确定，交给模型
  if (intent == null) return null;

  return LedgerQuerySpec(
    continueContext: continueContext,
    intent: intent,
    merchant: merchant,
    categoryId: categoryId,
    channel: channel,
    startDate: start,
    endDate: end,
    amount: amount,
  );
}

/// 查询解析提示词：只有几行，模型要读的字数在 200 字以内。
String ledgerQueryInstructions(DateTime now) =>
    '你是记账查询解析器。把用户这句话转成一行 JSON，不要解释、不要多余文字：\n'
    '{"continue_context":false,"intent":"sum","merchant":null,"category":null,'
    '"channel":null,"start_date":null,"end_date":null,"limit":null,"amount":null}\n'
    'intent 只能取：sum 求和｜count 笔数｜average 平均｜compare 和上一期对比｜'
    'top_merchant 哪个商户花最多｜top_category 哪个分类花最多｜latest 最近一笔｜'
    'monthly_summary 月度汇总｜find 找具体某几笔｜'
    'fuzzy 模糊找（用户只记得大概，比如"前几天买手机配件那笔"，说不清商户和分类时用）\n'
    '今天是 ${_compactDateFormatter.format(now)}。日期写成 yyyy-MM-dd。\n'
    'category 填中文分类名（餐饮/购物/出行/日常消费…）；channel 填 微信/支付宝/银行卡/现金。\n'
    '用户是在追问上一句（例如"那交通呢""上个月呢"）时，continue_context 填 true，'
    '并且只填这次变化的字段，其余留 null。';

/// 本地执行查询：求和、排序、统计都不经过模型。
class LedgerQueryOutcome {
  const LedgerQueryOutcome({
    required this.text,
    required this.entryIds,
    this.empty = false,
  });

  /// 给模型看的"数据"，一句话或几行数字。
  final String text;
  final List<String> entryIds;
  final bool empty;
}

LedgerQueryOutcome runLedgerQuery(
  LedgerBook book,
  LedgerQuerySpec spec, {
  DateTime? now,
  LedgerStatsIndex? statsIndex,
}) {
  final anchor = now ?? DateTime.now();
  DateTime? start = spec.startDate;
  DateTime? end = spec.endDate;
  // 只给了一个边界时补上另一端，避免"上个月"这类条件落空。
  if (start != null && end == null) {
    end = DateTime(start.year, start.month + 1, 0);
  }
  if (end != null && start == null) {
    start = DateTime(end.year, end.month, 1);
  }

  // 纯时间/分类的合计问题，直接用预生成统计，不必扫全表。
  final cachedCategoryOk =
      spec.categoryId == null ||
      categoryForId(spec.categoryId!).type == EntryType.expense;
  if (statsIndex != null &&
      spec.amount == null &&
      cachedCategoryOk &&
      spec.merchant == null &&
      spec.channel == null &&
      start != null &&
      end != null &&
      (spec.intent == 'sum' ||
          spec.intent == 'count' ||
          spec.intent == 'monthly_summary')) {
    final bucket = statsIndex.range(start, end);
    final expense = spec.categoryId == null
        ? bucket.expense
        : (bucket.byCategory[spec.categoryId] ?? 0);
    final scope = _describeScope(spec);
    if (bucket.count == 0) {
      return LedgerQueryOutcome(
        text: '$scope没有找到符合条件的流水。',
        entryIds: const [],
        empty: true,
      );
    }
    if (spec.intent == 'count') {
      return LedgerQueryOutcome(
        text: '$scope共${bucket.count}笔。',
        entryIds: const [],
      );
    }
    if (spec.intent == 'monthly_summary') {
      final top = bucket.byCategory.entries.toList()
        ..sort((a, b) => b.value.compareTo(a.value));
      final lines = top
          .take(3)
          .map((item) => '${categoryForId(item.key).name}${item.value.toStringAsFixed(2)}元')
          .join('、');
      return LedgerQueryOutcome(
        text:
            '$scope共${bucket.count}笔，收入${bucket.income.toStringAsFixed(2)}元，'
            '支出${bucket.expense.toStringAsFixed(2)}元；分类：${lines.isEmpty ? '暂无' : lines}。',
        entryIds: const [],
      );
    }
    // 和扫全表的说法保持一致，避免同一句话两种口吻。
    if (spec.categoryId == null) {
      return LedgerQueryOutcome(
        text:
            '$scope共${bucket.count}笔，收入${bucket.income.toStringAsFixed(2)}元，'
            '支出${bucket.expense.toStringAsFixed(2)}元。',
        entryIds: const [],
      );
    }
    final categoryCount = bucket.categoryCounts[spec.categoryId] ?? 0;
    return LedgerQueryOutcome(
      text:
          '$scope共$categoryCount笔，收入0.00元，支出${expense.toStringAsFixed(2)}元。',
      entryIds: const [],
    );
  }
  Iterable<LedgerEntry> matching() => book.entries.where((entry) {
    final date = entry.occurredAt;
    if (start != null && date.isBefore(start)) return false;
    if (end != null && date.isAfter(end.add(const Duration(days: 1)))) {
      return false;
    }
    if (spec.categoryId != null && entry.categoryId != spec.categoryId) {
      return false;
    }
    if (spec.channel != null && !_channelMatches(entry, spec.channel!)) {
      return false;
    }
    if (spec.merchant != null && !_merchantMatches(entry, spec.merchant!)) {
      return false;
    }
    // 记得金额时按金额精确找（±0.01 容忍浮点误差）
    if (spec.amount != null && (entry.amount - spec.amount!).abs() > 0.01) {
      return false;
    }
    return true;
  });

  final entries = matching().toList()
    ..sort((a, b) => b.occurredAt.compareTo(a.occurredAt));
  final income = entries
      .where((entry) => entry.type == EntryType.income)
      .fold<double>(0, (sum, entry) => sum + entry.amount);
  final expense = entries
      .where((entry) => entry.type == EntryType.expense)
      .fold<double>(0, (sum, entry) => sum + entry.amount);
  final scope = _describeScope(spec);

  if (entries.isEmpty) {
    return LedgerQueryOutcome(
      text: '$scope没有找到符合条件的流水。',
      entryIds: const [],
      empty: true,
    );
  }

  String money(double value) => value.toStringAsFixed(2);

  switch (spec.intent) {
    case 'count':
      return LedgerQueryOutcome(
        text: '$scope共${entries.length}笔。',
        entryIds: entries.take(50).map((e) => e.id).toList(),
      );
    case 'average':
      final average = entries.isEmpty ? 0.0 : (income + expense) / entries.length;
      return LedgerQueryOutcome(
        text: '$scope共${entries.length}笔，平均每笔${money(average)}元。',
        entryIds: entries.take(50).map((e) => e.id).toList(),
      );
    case 'compare':
      final length = (start != null && end != null)
          ? end.difference(start).inDays + 1
          : 30;
      final previousEnd = (start ?? anchor).subtract(const Duration(days: 1));
      final previousStart = previousEnd.subtract(Duration(days: length - 1));
      final previousSpec = LedgerQuerySpec(
        intent: 'sum',
        merchant: spec.merchant,
        categoryId: spec.categoryId,
        channel: spec.channel,
        startDate: previousStart,
        endDate: previousEnd,
      );
      final previous = runLedgerQuery(book, previousSpec, now: anchor);
      return LedgerQueryOutcome(
        text:
            '$scope支出${money(expense)}元；上一期（${_compactDateFormatter.format(previousStart)}'
            '~${_compactDateFormatter.format(previousEnd)}）${previous.text}',
        entryIds: entries.take(50).map((e) => e.id).toList(),
        empty: previous.empty,
      );
    case 'top_merchant':
      final grouped = _groupSum(entries, (entry) => entry.merchant);
      return LedgerQueryOutcome(
        text: '$scope花得最多的商户：${_topLines(grouped)}。',
        entryIds: entries.take(50).map((e) => e.id).toList(),
      );
    case 'top_category':
      final grouped = _groupSum(
        entries,
        (entry) => categoryForId(entry.categoryId).name,
      );
      return LedgerQueryOutcome(
        text: '$scope花得最多的分类：${_topLines(grouped)}。',
        entryIds: entries.take(50).map((e) => e.id).toList(),
      );
    case 'latest':
      final latest = entries.first;
      return LedgerQueryOutcome(
        text:
            '$scope最近一笔：${_compactDateFormatter.format(latest.occurredAt)} '
            '${categoryForId(latest.categoryId).name} ${latest.title} '
            '${latest.amount.toStringAsFixed(2)}元 商家：${latest.merchant}'
            '${latest.counterpartyName.isEmpty ? '' : ' 对方：${latest.counterpartyName}'}',
        entryIds: [latest.id],
      );
    case 'monthly_summary':
      final grouped = _groupSum(
        entries,
        (entry) => categoryForId(entry.categoryId).name,
      );
      return LedgerQueryOutcome(
        text:
            '$scope共${entries.length}笔，收入${money(income)}元，支出${money(expense)}元；'
            '分类：${_topLines(grouped)}。',
        entryIds: entries.take(50).map((e) => e.id).toList(),
      );
    case 'find':
      final limit = (spec.limit ?? 5).clamp(1, 15);
      final lines = entries
          .take(limit)
          .map(
            (entry) =>
                '${_compactDateFormatter.format(entry.occurredAt)} '
                '${entry.title} ${entry.amount.toStringAsFixed(2)}元 '
                '商家：${entry.merchant}'
                '${entry.counterpartyName.isEmpty ? '' : ' 对方：${entry.counterpartyName}'}',
          )
          .join('；');
      return LedgerQueryOutcome(
        text: '$scope找到${entries.length}笔，其中最近的：$lines',
        entryIds: entries.take(50).map((e) => e.id).toList(),
      );
    default:
      return LedgerQueryOutcome(
        text:
            '$scope共${entries.length}笔，收入${money(income)}元，支出${money(expense)}元。',
        entryIds: entries.take(50).map((e) => e.id).toList(),
      );
  }
}

bool _merchantMatches(LedgerEntry entry, String merchant) {
  final needle = merchant.replaceAll(RegExp(r'[\s·]'), '');
  final haystack =
      '${entry.merchant}${entry.title}${entry.counterpartyName}'.replaceAll(
        RegExp(r'[\s·]'),
        '',
      );
  return haystack.contains(needle);
}

bool _channelMatches(LedgerEntry entry, String channel) {
  final text = channel.trim();
  if (text.isEmpty) return true;
  return entry.sourceLabel.contains(text) || entry.channel.label.contains(text);
}

String _describeScope(LedgerQuerySpec spec) {
  final parts = <String>[
    if (spec.startDate != null && spec.endDate != null)
      '${_compactDateFormatter.format(spec.startDate!)}~'
          '${_compactDateFormatter.format(spec.endDate!)}'
    else if (spec.startDate != null)
      '${_compactDateFormatter.format(spec.startDate!)}起',
    if (spec.merchant != null) '商家含"${spec.merchant}"',
    if (spec.categoryId != null) '分类${categoryForId(spec.categoryId!).name}',
    if (spec.channel != null) '渠道${spec.channel}',
  ];
  return parts.isEmpty ? '' : '${parts.join('，')}：';
}

List<MapEntry<String, double>> _groupSum(
  List<LedgerEntry> entries,
  String Function(LedgerEntry entry) keyOf,
) {
  final grouped = <String, double>{};
  for (final entry in entries) {
    if (entry.type != EntryType.expense) continue;
    final key = keyOf(entry).trim();
    if (key.isEmpty || key == '未识别商户') continue;
    grouped.update(key, (value) => value + entry.amount, ifAbsent: () => entry.amount);
  }
  final sorted = grouped.entries.toList()
    ..sort((a, b) => b.value.compareTo(a.value));
  return sorted;
}

String _topLines(List<MapEntry<String, double>> grouped) {
  if (grouped.isEmpty) return '没有支出记录';
  return grouped
      .take(3)
      .map((item) => '${item.key}${item.value.toStringAsFixed(2)}元')
      .join('、');
}
