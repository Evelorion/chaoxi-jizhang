part of 'app.dart';

/// 一条通知原文，用来核对“收到什么 → 记成了什么”。
class RawNotificationRecord {
  const RawNotificationRecord({
    required this.id,
    required this.packageName,
    required this.sourceLabel,
    required this.title,
    required this.body,
    required this.profileId,
    required this.postedAt,
    required this.capturedAt,
    required this.status,
    required this.note,
  });

  final String id;
  final String packageName;
  final String sourceLabel;
  final String title;
  final String body;
  final int profileId;
  final DateTime postedAt;
  final DateTime capturedAt;
  final String status;
  final String note;

  bool get recognized => status == 'parsed';

  factory RawNotificationRecord.fromJson(Map<String, dynamic> json) =>
      RawNotificationRecord(
        id: json['id'] as String? ?? '',
        packageName: json['packageName'] as String? ?? '',
        sourceLabel: json['sourceLabel'] as String? ?? '',
        title: json['title'] as String? ?? '',
        body: json['body'] as String? ?? '',
        profileId: (json['profileId'] as num?)?.toInt() ?? 0,
        postedAt: DateTime.fromMillisecondsSinceEpoch(
          (json['postedAtMillis'] as num?)?.toInt() ?? 0,
        ),
        capturedAt: DateTime.fromMillisecondsSinceEpoch(
          (json['capturedAtMillis'] as num?)?.toInt() ?? 0,
        ),
        status: json['status'] as String? ?? 'unparsed',
        note: json['note'] as String? ?? '',
      );
}

/// 自动记账管道的运行情况，显示在设置页，让用户看得见进度。
class AutoCapturePipelineStats {
  const AutoCapturePipelineStats({
    required this.pendingCount,
    required this.capturedTotal,
    required this.parsedTotal,
    required this.unparsedCount,
    required this.droppedTotal,
  });

  final int pendingCount;
  final int capturedTotal;
  final int parsedTotal;
  final int unparsedCount;
  final int droppedTotal;

  static const empty = AutoCapturePipelineStats(
    pendingCount: 0,
    capturedTotal: 0,
    parsedTotal: 0,
    unparsedCount: 0,
    droppedTotal: 0,
  );

  factory AutoCapturePipelineStats.fromMap(Map<dynamic, dynamic> map) =>
      AutoCapturePipelineStats(
        pendingCount: (map['pendingCount'] as num?)?.toInt() ?? 0,
        capturedTotal: (map['capturedTotal'] as num?)?.toInt() ?? 0,
        parsedTotal: (map['parsedTotal'] as num?)?.toInt() ?? 0,
        unparsedCount: (map['unparsedCount'] as num?)?.toInt() ?? 0,
        droppedTotal:
            ((map['droppedTotal'] as num?)?.toInt() ?? 0) +
            ((map['pendingDroppedTotal'] as num?)?.toInt() ?? 0),
      );
}

/// 设置页里的“自动记账处理情况”卡片：看得到队列、进度和失败原因。
class AutoCapturePipelineCard extends ConsumerStatefulWidget {
  const AutoCapturePipelineCard({required this.book, super.key});

  final LedgerBook book;

  @override
  ConsumerState<AutoCapturePipelineCard> createState() =>
      _AutoCapturePipelineCardState();
}

class _AutoCapturePipelineCardState
    extends ConsumerState<AutoCapturePipelineCard>
    with WidgetsBindingObserver {
  static const _bridge = AndroidAutoCaptureBridge();
  Timer? _timer;
  AutoCapturePipelineStats _stats = AutoCapturePipelineStats.empty;
  bool _checking = false;
  bool _working = false;
  String? _notice;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    unawaited(_refresh());
    _timer = Timer.periodic(const Duration(seconds: 4), (_) {
      unawaited(_refresh());
    });
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) unawaited(_refresh());
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _timer?.cancel();
    super.dispose();
  }

  Future<void> _refresh() async {
    if (_checking) return;
    // 页面不可见时不用查询，省掉 4 秒一次的通道调用。
    if (!TickerMode.getNotifier(context).value) return;
    _checking = true;
    try {
      final stats = await _bridge.fetchStats();
      if (mounted) setState(() => _stats = stats);
    } catch (_) {
      // 读不到就保持上一次显示。
    } finally {
      _checking = false;
    }
  }

  Future<void> _syncNow() async {
    if (_working) return;
    setState(() => _working = true);
    try {
      await ref
          .read(ledgerControllerProvider.notifier)
          .syncAutoCapturedEntries();
    } finally {
      if (mounted) setState(() => _working = false);
      await _refresh();
    }
  }

  /// 标了「待确认」的自动记账条目：千问没能给出可用字段，先记下来等你核对。
  int get _pendingReviewCount {
    final entries = ref.watch(ledgerControllerProvider).book?.entries ?? const [];
    return entries
        .where(
          (entry) =>
              entry.autoCaptured && entry.tags.contains(_needsReviewTag),
        )
        .length;
  }

  String get _summary {
    if (!widget.book.settings.autoCaptureEnabled) return '自动记账主开关已关闭';
    if (!ref.read(ledgerControllerProvider).notificationAccessGranted) {
      return '还没有通知读取权限，去上面的自动记账设置里授权';
    }
    final pending = _stats.pendingCount;
    if (pending > 0) {
      return '有 $pending 条在等千问处理，切到后台也会继续整理';
    }
    if (_pendingReviewCount > 0) {
      return '有 $_pendingReviewCount 条千问没看懂，已记成待确认，改一次分类它就会记住';
    }
    return '队列已清空，新的支付通知会由千问生成账单';
  }

  /// 自动记账走了哪条路：模板 / 商户缓存 / 千问。数字越大说明越省模型。
  String get _pathLine {
    final stats = ref.watch(ledgerControllerProvider).book?.capturePathStats;
    if (stats == null || stats.isEmpty) return '';
    final template = stats['template'] ?? 0;
    final cache = stats['cache'] ?? 0;
    final ai = stats['ai'] ?? 0;
    final total = template + cache + ai;
    if (total == 0) return '';
    final saved = ((template + cache) * 100 / total).round();
    return '已处理 $total 条：不用模型 $saved%（模板 $template · 商户缓存 $cache · 千问 $ai）';
  }

  /// 学到的东西：哪个 App 的通知来得慢、常见的通知顺序是什么。
  /// 这些是系统自己观察出来的，不是写死的规则。
  String get _learnedLine {
    final book = ref.watch(ledgerControllerProvider).book;
    if (book == null) return '';
    final parts = <String>[];
    final profile = book.captureDelayProfile;
    if (profile.isNotEmpty) {
      final slowest = profile.entries.toList()
        ..sort((a, b) => b.value.compareTo(a.value));
      final top = slowest.first;
      if (top.value >= 5000) {
        final source = CaptureSource.values.firstWhere(
          (item) => item.name == top.key,
          orElse: () => CaptureSource.unknown,
        );
        if (source != CaptureSource.unknown) {
          parts.add(
            '${source.label}通知最晚要等 ${(top.value / 1000).round()} 秒',
          );
        }
      }
    }
    final sequence = topCaptureSequenceLabel(book.captureSequence);
    if (sequence.isNotEmpty) parts.add(sequence);
    return parts.join(' · ');
  }

  String get _statsLine {
    final review = _pendingReviewCount;
    final parts = <String>[
      '收到支付通知 ${_stats.capturedTotal} 条',
      if (review > 0) '待确认 $review 条',
      '已识别 ${_stats.parsedTotal} 条',
      if (_stats.unparsedCount > 0) '没认出 ${_stats.unparsedCount} 条',
      if (_stats.droppedTotal > 0) '因积压丢弃 ${_stats.droppedTotal} 条',
    ];
    return parts.join(' · ');
  }

  @override
  Widget build(BuildContext context) {
    final pending = _stats.pendingCount;
    return _GlassCard(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          ListTile(
            contentPadding: EdgeInsets.zero,
            leading: Container(
              padding: const EdgeInsets.all(8),
              decoration: BoxDecoration(
                color: const Color(0xFFE8F5E9),
                borderRadius: BorderRadius.circular(12),
              ),
              child: Icon(
                pending > 0
                    ? Icons.pending_actions_rounded
                    : Icons.check_circle_outline_rounded,
                color: const Color(0xFF2E7D32),
                size: 22,
              ),
            ),
            title: const Text('自动记账处理情况'),
            subtitle: Text(_summary),
            trailing: _working
                ? const SizedBox(
                    width: 20,
                    height: 20,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  )
                : IconButton(
                    tooltip: '立即处理',
                    onPressed: _syncNow,
                    icon: const Icon(Icons.refresh_rounded),
                  ),
          ),
          Text(
            _statsLine,
            style: const TextStyle(fontSize: 12, color: Color(0xFF7A869C)),
          ),
          if (_pathLine.isNotEmpty)
            Padding(
              padding: const EdgeInsets.only(top: 4),
              child: Text(
                _pathLine,
                style: const TextStyle(fontSize: 12, color: Color(0xFF2E7D32)),
              ),
            ),
          if (_learnedLine.isNotEmpty)
            Padding(
              padding: const EdgeInsets.only(top: 4),
              child: Text(
                _learnedLine,
                style: const TextStyle(fontSize: 12, color: Color(0xFF5A6A80)),
              ),
            ),
          if (_notice != null)
            Padding(
              padding: const EdgeInsets.only(top: 4),
              child: Text(
                _notice!,
                style: const TextStyle(fontSize: 12, color: Color(0xFFE65100)),
              ),
            ),
          const SizedBox(height: 8),
          Wrap(
            spacing: 8,
            runSpacing: 8,
            children: [
              OutlinedButton.icon(
                onPressed: _working ? null : _syncNow,
                icon: const Icon(Icons.play_arrow_rounded),
                label: const Text('立即处理'),
              ),
              TextButton.icon(
                onPressed: () => Navigator.of(context).push(
                  MaterialPageRoute<void>(
                    builder: (_) => const RawNotificationsPage(),
                  ),
                ),
                icon: const Icon(Icons.receipt_long_rounded),
                label: const Text('查看通知原文'),
              ),
            ],
          ),
        ],
      ),
    );
  }
}

/// 通知原文列表：每条通知收到了什么、有没有被识别成账单。
class RawNotificationsPage extends StatefulWidget {
  const RawNotificationsPage({super.key});

  @override
  State<RawNotificationsPage> createState() => _RawNotificationsPageState();
}

class _RawNotificationsPageState extends State<RawNotificationsPage> {
  static const _bridge = AndroidAutoCaptureBridge();
  List<RawNotificationRecord> _records = const [];
  bool _loading = true;

  @override
  void initState() {
    super.initState();
    unawaited(_load());
  }

  Future<void> _load() async {
    try {
      final records = await _bridge.fetchRawNotifications(limit: 100);
      if (mounted) {
        setState(() {
          _records = records;
          _loading = false;
        });
      }
    } catch (_) {
      if (mounted) setState(() => _loading = false);
    }
  }

  Future<void> _clear() async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('清空通知原文？'),
        content: const Text('只清掉这里的原文记录，已经记好的账单不受影响。'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('先不清'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, true),
            child: const Text('清空'),
          ),
        ],
      ),
    );
    if (confirmed != true) return;
    await _bridge.clearRawNotifications();
    await _load();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('通知原文'),
        actions: [
          IconButton(
            tooltip: '刷新',
            onPressed: () => unawaited(_load()),
            icon: const Icon(Icons.refresh_rounded),
          ),
          IconButton(
            tooltip: '清空',
            onPressed: _records.isEmpty ? null : _clear,
            icon: const Icon(Icons.delete_outline_rounded),
          ),
        ],
      ),
      body: _loading
          ? const Center(child: CircularProgressIndicator())
          : _records.isEmpty
          ? const Center(
              child: Padding(
                padding: EdgeInsets.all(32),
                child: Text(
                  '还没有收到过支付类通知。\n收到微信、支付宝等付款通知后，'
                  '这里会留下原文，方便你核对记成了什么。',
                  textAlign: TextAlign.center,
                ),
              ),
            )
          : ListView.separated(
              padding: const EdgeInsets.fromLTRB(16, 12, 16, 32),
              itemCount: _records.length,
              separatorBuilder: (_, _) => const SizedBox(height: 10),
              itemBuilder: (context, index) =>
                  _RawNotificationTile(record: _records[index]),
            ),
    );
  }
}

class _RawNotificationTile extends StatelessWidget {
  const _RawNotificationTile({required this.record});

  final RawNotificationRecord record;

  @override
  Widget build(BuildContext context) {
    final recognized = record.recognized;
    final noteText = record.note.isEmpty ? '' : '（${record.note}）';
    return _GlassCard(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(
                recognized
                    ? Icons.check_circle_rounded
                    : Icons.help_outline_rounded,
                size: 18,
                color: recognized
                    ? const Color(0xFF2E7D32)
                    : const Color(0xFFE65100),
              ),
              const SizedBox(width: 6),
              Text(
                record.sourceLabel,
                style: const TextStyle(fontWeight: FontWeight.w700),
              ),
              const Spacer(),
              Text(
                '${_compactDateFormatter.format(record.postedAt)} '
                '${DateFormat('HH:mm').format(record.postedAt)}',
                style: const TextStyle(fontSize: 12, color: Color(0xFF7A869C)),
              ),
            ],
          ),
          const SizedBox(height: 6),
          if (record.title.isNotEmpty)
            Text(
              record.title,
              style: const TextStyle(fontWeight: FontWeight.w600),
            ),
          if (record.body.isNotEmpty)
            Padding(
              padding: const EdgeInsets.only(top: 2),
              child: Text(
                record.body,
                style: const TextStyle(color: Color(0xFF5A6B85), height: 1.4),
              ),
            ),
          const SizedBox(height: 6),
          Text(
            recognized ? '已识别为账单$noteText' : '没能识别成账单$noteText',
            style: TextStyle(
              fontSize: 12,
              color: recognized
                  ? const Color(0xFF2E7D32)
                  : const Color(0xFFE65100),
            ),
          ),
        ],
      ),
    );
  }
}
