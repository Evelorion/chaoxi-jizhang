part of 'app.dart';

/// 中文没有空格，这里用「字符 bigram + 短词整词」当检索词，
/// 不引入分词库也能让"手机配件"命中"数码配件店"。
List<String> ledgerSearchTokens(String text) {
  final cleaned = text
      .toLowerCase()
      .replaceAll(RegExp(r'[^0-9a-z\u4e00-\u9fa5]+'), ' ')
      .trim();
  if (cleaned.isEmpty) return const [];
  final tokens = <String>[];
  for (final chunk in cleaned.split(' ')) {
    if (chunk.isEmpty) continue;
    final runes = chunk.runes.map(String.fromCharCode).toList();
    if (runes.length <= 1 || RegExp(r'^[0-9.]+$').hasMatch(chunk)) {
      tokens.add(chunk);
      continue;
    }
    for (var i = 0; i + 1 < runes.length; i++) {
      tokens.add('${runes[i]}${runes[i + 1]}');
    }
    if (runes.length <= 4) tokens.add(chunk);
  }
  return tokens;
}

/// 一条流水参与检索时用到的全部文字。
/// 商户、标题、备注、标签、分类名都算上 —— 用户可能记得的是其中任何一个。
String ledgerSearchText(LedgerEntry entry) => [
  entry.title,
  entry.merchant,
  entry.counterpartyName,
  entry.note,
  entry.tags.join(' '),
  categoryForId(entry.categoryId).name,
  entry.sourceLabel,
  entry.fundingAccount,
  entry.amount.toStringAsFixed(2),
].join(' ');

/// 分类关键词也算成语义线索：问"打车"时，出行分类下的关键词会一起命中。
List<String> _categoryKeywordTokens(LedgerEntry entry) {
  final category = categoryForId(entry.categoryId);
  return [for (final keyword in category.keywords) ...ledgerSearchTokens(keyword)];
}

/// 稀疏向量：检索词 → 权重。这是本地向量检索，不需要额外的 embedding 模型。
Map<String, double> ledgerSearchVector(
  List<String> tokens, {
  Map<String, int>? documentFrequency,
  int documentCount = 1,
}) {
  if (tokens.isEmpty) return const {};
  final counts = <String, int>{};
  for (final token in tokens) {
    counts.update(token, (value) => value + 1, ifAbsent: () => 1);
  }
  final vector = <String, double>{};
  counts.forEach((token, count) {
    final tf = 1 + math.log(count.toDouble());
    final df = documentFrequency?[token] ?? 1;
    final idf = math.log((documentCount + 1) / (df + 1)) + 1;
    vector[token] = tf * idf;
  });
  return vector;
}

double ledgerCosine(Map<String, double> a, Map<String, double> b) {
  if (a.isEmpty || b.isEmpty) return 0;
  var dot = 0.0;
  var normA = 0.0;
  var normB = 0.0;
  a.forEach((token, value) {
    normA += value * value;
    final other = b[token];
    if (other != null) dot += value * other;
  });
  b.forEach((token, value) {
    normB += value * value;
  });
  if (normA == 0 || normB == 0) return 0;
  return dot / (math.sqrt(normA) * math.sqrt(normB));
}

/// 一次模糊检索的结果。
class LedgerSearchHit {
  const LedgerSearchHit({
    required this.entry,
    required this.lexical,
    required this.semantic,
    required this.score,
  });

  final LedgerEntry entry;

  /// 全文命中（bigram 重叠）
  final double lexical;

  /// 向量余弦（含分类关键词的语义线索）
  final double semantic;

  /// 综合分：越相关越靠前
  final double score;
}

/// 模糊查找：先全文检索筛出候选，再用向量余弦重排，最后按时间做轻微加权。
/// 结构化问题（有明确商户/分类/时间）不该走这里，那条路是精确计算。
List<LedgerSearchHit> searchLedgerFuzzy(
  LedgerBook book,
  String query, {
  int limit = 5,
  int candidateLimit = 20,
  DateTime? now,
}) {
  final queryTokens = ledgerSearchTokens(query);
  if (queryTokens.isEmpty || book.entries.isEmpty) return const [];

  final anchor = now ?? DateTime.now();
  final docTokens = <String, List<String>>{};
  final documentFrequency = <String, int>{};
  for (final entry in book.entries) {
    final tokens = [
      ...ledgerSearchTokens(ledgerSearchText(entry)),
      ..._categoryKeywordTokens(entry),
    ];
    docTokens[entry.id] = tokens;
    for (final token in tokens.toSet()) {
      documentFrequency.update(token, (value) => value + 1, ifAbsent: () => 1);
    }
  }

  final queryVector = ledgerSearchVector(
    queryTokens,
    documentFrequency: documentFrequency,
    documentCount: book.entries.length,
  );
  final querySet = queryTokens.toSet();

  // 第一段：全文命中，先筛出候选（避免给后面的重排太多噪声）
  final lexicalScores = <String, double>{};
  for (final entry in book.entries) {
    final tokens = docTokens[entry.id] ?? const [];
    if (tokens.isEmpty) continue;
    var hits = 0;
    for (final token in tokens) {
      if (querySet.contains(token)) hits++;
    }
    if (hits == 0) continue;
    lexicalScores[entry.id] = hits / (tokens.length + 1);
  }
  if (lexicalScores.isEmpty) return const [];

  final candidates = lexicalScores.entries.toList()
    ..sort((a, b) => b.value.compareTo(a.value));
  final shortlist = candidates.take(candidateLimit).map((item) => item.key).toSet();

  // 第二段：向量余弦重排
  final hits = <LedgerSearchHit>[];
  for (final entry in book.entries) {
    if (!shortlist.contains(entry.id)) continue;
    final vector = ledgerSearchVector(
      docTokens[entry.id] ?? const [],
      documentFrequency: documentFrequency,
      documentCount: book.entries.length,
    );
    final semantic = ledgerCosine(queryVector, vector);
    final lexical = lexicalScores[entry.id] ?? 0;
    // 时间加权：越近的越可能是"前几天那笔"，但权重很小，不盖过相关性。
    final days = anchor.difference(entry.occurredAt).inDays.abs();
    final recency = days <= 7
        ? 0.12
        : days <= 30
        ? 0.06
        : 0.0;
    hits.add(
      LedgerSearchHit(
        entry: entry,
        lexical: lexical,
        semantic: semantic,
        score: lexical * 0.6 + semantic * 0.4 + recency,
      ),
    );
  }
  hits.sort((a, b) => b.score.compareTo(a.score));
  return hits.take(limit).toList();
}

/// 把候选流水写成给模型看的一行行数据（模型只负责说人话）。
String describeSearchHits(List<LedgerSearchHit> hits) {
  if (hits.isEmpty) return '没有找到相关的流水。';
  final lines = <String>[
    for (var i = 0; i < hits.length; i++)
      '${i + 1}. ${_compactDateFormatter.format(hits[i].entry.occurredAt)} '
          '${hits[i].entry.title} ${hits[i].entry.amount.toStringAsFixed(2)}元 '
          '商户：${hits[i].entry.merchant.isEmpty ? '未记录' : hits[i].entry.merchant}'
          '${hits[i].entry.note.isEmpty ? '' : ' 备注：${_shortLocalAiText(hits[i].entry.note, 24)}'}',
  ];
  return lines.join('\n');
}
