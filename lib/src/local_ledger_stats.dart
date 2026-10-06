part of 'app.dart';

/// #13 按天/按月的统计结果。
class LedgerBucketStats {
  const LedgerBucketStats({
    this.expense = 0,
    this.income = 0,
    this.count = 0,
    this.byCategory = const {},
    this.categoryCounts = const {},
  });

  final double expense;
  final double income;
  final int count;
  final Map<String, double> byCategory;

  /// 分类 → 笔数（只统计支出），用来回答"餐饮花了多少"时给出笔数。
  final Map<String, int> categoryCounts;

  double get net => income - expense;
}

/// #13 预生成统计：账本一变就重建，之后"今天花了多少"这类问题不必再扫全表。
class LedgerStatsIndex {
  const LedgerStatsIndex({
    required this.days,
    required this.months,
    required this.entryCount,
  });

  /// 'yyyy-MM-dd' → 当天统计
  final Map<String, LedgerBucketStats> days;

  /// 'yyyy-MM' → 当月统计
  final Map<String, LedgerBucketStats> months;

  /// 建索引时的流水条数（用来判断缓存是否过期）。
  final int entryCount;

  static const empty = LedgerStatsIndex(
    days: {},
    months: {},
    entryCount: 0,
  );

  static String dayKey(DateTime time) =>
      '${time.year.toString().padLeft(4, '0')}-'
      '${time.month.toString().padLeft(2, '0')}-'
      '${time.day.toString().padLeft(2, '0')}';

  static String monthKey(DateTime time) =>
      '${time.year.toString().padLeft(4, '0')}-'
      '${time.month.toString().padLeft(2, '0')}';

  /// 取出某个时间段的合计（闭区间）。
  LedgerBucketStats range(DateTime start, DateTime end) {
    var expense = 0.0;
    var income = 0.0;
    var count = 0;
    final byCategory = <String, double>{};
    final categoryCounts = <String, int>{};
    var cursor = DateTime(start.year, start.month, start.day);
    final last = DateTime(end.year, end.month, end.day);
    while (!cursor.isAfter(last)) {
      final bucket = days[dayKey(cursor)];
      if (bucket != null) {
        expense += bucket.expense;
        income += bucket.income;
        count += bucket.count;
        bucket.byCategory.forEach((key, value) {
          byCategory.update(key, (old) => old + value, ifAbsent: () => value);
        });
        bucket.categoryCounts.forEach((key, value) {
          categoryCounts.update(key, (old) => old + value, ifAbsent: () => value);
        });
      }
      cursor = cursor.add(const Duration(days: 1));
    }
    return LedgerBucketStats(
      expense: expense,
      income: income,
      count: count,
      byCategory: byCategory,
      categoryCounts: categoryCounts,
    );
  }
}

/// 建索引：一次遍历，按天和按月各记一份。
LedgerStatsIndex buildLedgerStatsIndex(LedgerBook book) {
  if (book.entries.isEmpty) return LedgerStatsIndex.empty;
  final days = <String, LedgerBucketStats>{};
  final months = <String, LedgerBucketStats>{};
  for (final entry in book.entries) {
    final dayKey = LedgerStatsIndex.dayKey(entry.occurredAt);
    final monthKey = LedgerStatsIndex.monthKey(entry.occurredAt);
    days[dayKey] = _mergeBucket(days[dayKey], entry);
    months[monthKey] = _mergeBucket(months[monthKey], entry);
  }
  return LedgerStatsIndex(
    days: days,
    months: months,
    entryCount: book.entries.length,
  );
}

LedgerBucketStats _mergeBucket(LedgerBucketStats? current, LedgerEntry entry) {
  final base = current ?? const LedgerBucketStats();
  final byCategory = {...base.byCategory};
  final categoryCounts = {...base.categoryCounts};
  if (entry.type == EntryType.expense) {
    byCategory.update(
      entry.categoryId,
      (old) => old + entry.amount,
      ifAbsent: () => entry.amount,
    );
    categoryCounts.update(
      entry.categoryId,
      (old) => old + 1,
      ifAbsent: () => 1,
    );
  }
  return LedgerBucketStats(
    expense: base.expense + (entry.type == EntryType.expense ? entry.amount : 0),
    income: base.income + (entry.type == EntryType.income ? entry.amount : 0),
    count: base.count + 1,
    byCategory: byCategory,
    categoryCounts: categoryCounts,
  );
}

/// #10 每个字段的最低可信度：金额错了最严重，分类错一点关系不大。
const captureFieldThresholds = <String, double>{
  'amount': 0.95,
  'type': 0.90,
  'account': 0.85,
  'merchant': 0.75,
  'category': 0.65,
};

/// 按字段阈值判断哪些字段需要人工看一眼。
/// 金额/收支方向由通知解析给出（等同 1.0），所以实际只会是商户和分类。
Set<String> fieldsNeedingReview({
  required double merchantConfidence,
  required double categoryConfidence,
}) => {
  if (merchantConfidence < captureFieldThresholds['merchant']!) 'merchant',
  if (categoryConfidence < captureFieldThresholds['category']!) 'category',
};
