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

/// 查询解析提示词：只有几行，模型要读的字数在 200 字以内。
String ledgerQueryInstructions(DateTime now) =>
    '你是记账查询解析器。把用户这句话转成一行 JSON，不要解释、不要多余文字：\n'
    '{"continue_context":false,"intent":"sum","merchant":null,"category":null,'
    '"channel":null,"start_date":null,"end_date":null,"limit":null}\n'
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
          '$scope共${categoryCount}笔，收入0.00元，支出${expense.toStringAsFixed(2)}元。',
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
