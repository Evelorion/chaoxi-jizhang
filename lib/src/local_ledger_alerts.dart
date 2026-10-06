part of 'app.dart';

/// 一条异常提醒。数字全部由本地统计算出来，模型只负责把它说成人话。
class LedgerAnomaly {
  const LedgerAnomaly({
    required this.kind,
    required this.title,
    required this.detail,
    required this.entryIds,
  });

  /// duplicate 疑似重复扣款｜priceJump 比平时贵｜bigAmount 金额异常
  final String kind;
  final String title;

  /// 给模型看的数字，例如"本次 30.00 元，过去 5 次中位数 15.00 元，高了 100%"。
  final String detail;
  final List<String> entryIds;
}

/// 异常提醒：统计程序发现，AI 只负责解释。
List<LedgerAnomaly> detectLedgerAnomalies(
  LedgerBook book, {
  DateTime? now,
  int maxItems = 5,
}) {
  final anchor = now ?? DateTime.now();
  final recent = book.entries
      .where(
        (entry) =>
            anchor.difference(entry.occurredAt).inDays.abs() <= 60 &&
            entry.type == EntryType.expense,
      )
      .toList()
    ..sort((a, b) => b.occurredAt.compareTo(a.occurredAt));
  if (recent.isEmpty) return const [];

  final anomalies = <LedgerAnomaly>[];

  // ① 疑似重复扣款：同商户 + 同金额 + 10 分钟内出现两次
  for (var i = 0; i < recent.length; i++) {
    final current = recent[i];
    if (current.merchant.trim().isEmpty) continue;
    for (var j = i + 1; j < recent.length; j++) {
      final other = recent[j];
      if (other.merchant.trim() != current.merchant.trim()) continue;
      if ((other.amount - current.amount).abs() > 0.01) continue;
      final gap = current.occurredAt
          .difference(other.occurredAt)
          .inMinutes
          .abs();
      if (gap > 10) break;
      anomalies.add(
        LedgerAnomaly(
          kind: 'duplicate',
          title: '疑似重复扣款：${current.merchant}',
          detail:
              '同一商户「${current.merchant}」在 $gap 分钟内各扣了'
              '${current.amount.toStringAsFixed(2)}元（'
              '${_compactDateFormatter.format(other.occurredAt)} 与 '
              '${_compactDateFormatter.format(current.occurredAt)}）。',
          entryIds: [current.id, other.id],
        ),
      );
      break;
    }
    if (anomalies.length >= maxItems) break;
  }

  // ② 同一商户金额突然变高：本次 > 历史中位数 × 1.8
  final byMerchant = <String, List<LedgerEntry>>{};
  for (final entry in recent) {
    final merchant = entry.merchant.trim();
    if (merchant.isEmpty || merchant == '未识别商户') continue;
    byMerchant.putIfAbsent(merchant, () => []).add(entry);
  }
  byMerchant.forEach((merchant, entries) {
    if (entries.length < 4 || anomalies.length >= maxItems) return;
    final sorted = [...entries]
      ..sort((a, b) => a.occurredAt.compareTo(b.occurredAt));
    final current = sorted.last;
    if (anchor.difference(current.occurredAt).inDays > 14) return;
    final history =
        sorted.sublist(0, sorted.length - 1).map((e) => e.amount).toList()
          ..sort();
    final median = history[history.length ~/ 2];
    if (median <= 0) return;
    if (current.amount <= median * 1.8) return;
    final change = ((current.amount - median) / median * 100).round();
    anomalies.add(
      LedgerAnomaly(
        kind: 'priceJump',
        title: '$merchant 这次比平时贵',
        detail:
            '「$merchant」本次 ${current.amount.toStringAsFixed(2)} 元，'
            '过去 ${history.length} 次中位数 ${median.toStringAsFixed(2)} 元，'
            '高了 $change%。',
        entryIds: [current.id],
      ),
    );
  });

  // ③ 金额异常：最近 7 天出现远超日常水平的一笔
  final amounts = recent.map((entry) => entry.amount).toList()..sort();
  final overallMedian = amounts[amounts.length ~/ 2];
  if (overallMedian > 0) {
    for (final entry in recent) {
      if (anomalies.length >= maxItems) break;
      if (anchor.difference(entry.occurredAt).inDays > 7) break;
      if (entry.amount < 200) continue;
      if (entry.amount <= overallMedian * 3) continue;
      if (anomalies.any((item) => item.entryIds.contains(entry.id))) continue;
      anomalies.add(
        LedgerAnomaly(
          kind: 'bigAmount',
          title: '金额明显高于日常',
          detail:
              '${_compactDateFormatter.format(entry.occurredAt)} 的「${entry.title}」'
              '${entry.amount.toStringAsFixed(2)} 元，'
              '日常单笔中位数只有 ${overallMedian.toStringAsFixed(2)} 元。',
          entryIds: [entry.id],
        ),
      );
    }
  }

  return anomalies.take(maxItems).toList();
}

/// 异常提醒卡片：只做统计和解释，不下"这是欺诈"这种结论。
class LedgerAnomalyCard extends ConsumerStatefulWidget {
  const LedgerAnomalyCard({required this.book, super.key});

  final LedgerBook book;

  @override
  ConsumerState<LedgerAnomalyCard> createState() => _LedgerAnomalyCardState();
}

class _LedgerAnomalyCardState extends ConsumerState<LedgerAnomalyCard> {
  final Map<String, String> _explanations = {};
  String? _running;

  Future<void> _explain(LedgerAnomaly anomaly) async {
    if (_running != null) return;
    setState(() => _running = anomaly.detail);
    try {
      final model = _selectedLocalAiModel(widget.book.settings);
      if (!await _isInstalled(model)) {
        if (mounted) {
          setState(() {
            _running = null;
            _explanations[anomaly.detail] = '先装好离线千问模型才能解释。';
          });
        }
        return;
      }
      final llama = await LocalAiEngine.acquire(await _localAiModelPath(model));
      await llama.clearContext();
      final raw = await llama
          .generateChat(
            messages: [
              ChatMessage(
                role: 'system',
                content: '你是账本助手。只根据给出的数字用一句中文提醒用户，'
                    '不要下"这是欺诈"这类结论，也不要编造数字。',
              ),
              ChatMessage(
                role: 'user',
                content: '${anomaly.detail}\n请用一句中文提醒我。',
              ),
            ],
            template: 'chatml',
            maxTokens: 100,
            temperature: 0.2,
          )
          .join();
      final text = _visibleLocalAiAnswer(raw);
      if (mounted) {
        setState(() {
          _running = null;
          _explanations[anomaly.detail] = text.isEmpty ? anomaly.detail : text;
        });
      }
    } catch (_) {
      if (mounted) {
        setState(() {
          _running = null;
          _explanations[anomaly.detail] = '这次没能让千问解释，稍后再试。';
        });
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final anomalies = detectLedgerAnomalies(widget.book);
    if (anomalies.isEmpty) return const SizedBox.shrink();
    return _GlassCard(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Text(
            '异常提醒',
            style: TextStyle(fontWeight: FontWeight.w700, fontSize: 16),
          ),
          const SizedBox(height: 4),
          const Text(
            '这些是本地统计发现的异常，只作提醒，不代表一定有问题。',
            style: TextStyle(fontSize: 12, color: Color(0xFF7A869C)),
          ),
          const SizedBox(height: 12),
          for (final anomaly in anomalies)
            Padding(
              padding: const EdgeInsets.only(bottom: 10),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      Icon(
                        anomaly.kind == 'duplicate'
                            ? Icons.copy_all_rounded
                            : Icons.trending_up_rounded,
                        size: 18,
                        color: const Color(0xFFE65100),
                      ),
                      const SizedBox(width: 6),
                      Expanded(
                        child: Text(
                          anomaly.title,
                          style: const TextStyle(fontWeight: FontWeight.w600),
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 2),
                  Text(
                    _explanations[anomaly.detail] ?? anomaly.detail,
                    style: const TextStyle(
                      fontSize: 12,
                      color: Color(0xFF5A6A80),
                      height: 1.4,
                    ),
                  ),
                  if (_explanations[anomaly.detail] == null)
                    TextButton(
                      onPressed: _running == null
                          ? () => _explain(anomaly)
                          : null,
                      child: Text(
                        _running == anomaly.detail ? '正在让千问解释…' : '让千问说一句',
                      ),
                    ),
                ],
              ),
            ),
        ],
      ),
    );
  }
}
