part of 'app.dart';

/// 设置页里的一个小入口，点进去才是下载和删除。
class LocalAiModelSettingsEntry extends ConsumerStatefulWidget {
  const LocalAiModelSettingsEntry({required this.book, super.key});

  final LedgerBook book;

  @override
  ConsumerState<LocalAiModelSettingsEntry> createState() =>
      _LocalAiModelSettingsEntryState();
}

class _LocalAiModelSettingsEntryState
    extends ConsumerState<LocalAiModelSettingsEntry>
    with WidgetsBindingObserver {
  final LocalAiDownloadBridge _bridge = const LocalAiDownloadBridge();
  Timer? _timer;
  LocalAiModel _model = LocalAiModel.available.first;
  LocalAiDownloadStatus _status = LocalAiDownloadStatus.idle;
  bool _installed = false;
  bool _checking = false;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    unawaited(_refresh());
    _timer = Timer.periodic(
      const Duration(seconds: 3),
      (_) => unawaited(_refresh()),
    );
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
    // 不显示的时候不做任何查询，省掉 3 秒一次的通道调用和读文件。
    if (!TickerMode.getNotifier(context).value) return;
    _checking = true;
    try {
      final model = _selectedLocalAiModel(
        ref.read(ledgerControllerProvider).book?.settings,
      );
      final status = await _bridge.query(model);
      final installed = await _isInstalled(model);
      if (!installed && await _localAiDownloadReadyToVerify(model, status)) {
        try {
          // 文件齐了就先校验；校验通过后让系统下载服务停下，别再无谓重试。
          await _verifyCompletedLocalAiDownload(model);
          await _bridge.cancel(model);
        } catch (_) {
          // 校验失败交给设置页处理，这里只负责显示状态。
        }
      }
      final verified = installed || await _isInstalled(model);
      if (!mounted) return;
      setState(() {
        _model = model;
        _status = status;
        _installed = verified;
      });
    } catch (_) {
      // 状态读不到时保留上一次显示，不打扰用户。
    } finally {
      _checking = false;
    }
  }

  String get _summary {
    if (_installed) return '已装好 · ${_model.name} · 可以离线问答';
    if (_status.isActive) {
      final percent = _status.progress;
      final progress = percent == null
          ? ''
          : ' ${(percent * 100).clamp(0, 99).toStringAsFixed(0)}%';
      return '正在后台下载$progress · 退出应用也会继续';
    }
    if (_status.state == 'failed') return '上次没下成功 · 点这里重试';
    return '还没有下载 · 点这里选版本';
  }

  @override
  Widget build(BuildContext context) {
    return _GlassCard(
      child: ListTile(
        contentPadding: EdgeInsets.zero,
        leading: Container(
          padding: const EdgeInsets.all(8),
          decoration: BoxDecoration(
            color: const Color(0xFFE8EAF6),
            borderRadius: BorderRadius.circular(12),
          ),
          child: Icon(
            _installed ? Icons.memory_rounded : Icons.download_rounded,
            color: const Color(0xFF5C6BC0),
            size: 22,
          ),
        ),
        title: const Text('离线千问（本地 AI）'),
        subtitle: Text(_summary),
        trailing: _status.isActive && _status.progress != null
            ? SizedBox(
                width: 34,
                height: 34,
                child: CircularProgressIndicator(
                  strokeWidth: 3,
                  value: _status.progress,
                  semanticsLabel: '模型下载进度',
                ),
              )
            : const Icon(Icons.chevron_right_rounded),
        onTap: () async {
          await Navigator.of(context).push(
            MaterialPageRoute<void>(
              builder: (_) => const LocalAiModelSettingsPage(),
            ),
          );
          if (mounted) unawaited(_refresh());
        },
      ),
    );
  }
}

class LocalAiModelSettingsPage extends ConsumerStatefulWidget {
  const LocalAiModelSettingsPage({super.key});

  @override
  ConsumerState<LocalAiModelSettingsPage> createState() =>
      _LocalAiModelSettingsPageState();
}

class _LocalAiModelSettingsPageState
    extends ConsumerState<LocalAiModelSettingsPage>
    with WidgetsBindingObserver {
  final LocalAiDownloadBridge _bridge = const LocalAiDownloadBridge();
  final Map<String, LocalAiDownloadStatus> _statuses = {};
  final Set<String> _installed = {};
  final Set<String> _verifying = {};
  final Set<String> _changing = {};
  final Map<String, int> _redownloads = {};
  Timer? _pollTimer;
  bool _refreshing = false;
  bool _useMirror = false;
  bool _runnable = true;
  bool _savingSpec = false;
  late final TextEditingController _specController;
  String? _error;
  String? _notice;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _specController = TextEditingController(
      text:
          ref.read(ledgerControllerProvider).book?.settings.aiCaptureSpec ??
          defaultAiCaptureSpec,
    );
    unawaited(_loadCapability());
    unawaited(_refresh());
    _pollTimer = Timer.periodic(const Duration(seconds: 2), (_) {
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
    _pollTimer?.cancel();
    _specController.dispose();
    super.dispose();
  }

  Future<void> _loadCapability() async {
    final runnable = await LocalAiCapability.canRun();
    if (mounted) setState(() => _runnable = runnable);
  }

  Future<void> _refresh() async {
    if (_refreshing) return;
    _refreshing = true;
    try {
      final statuses = <String, LocalAiDownloadStatus>{};
      final installed = <String>{};
      for (final model in LocalAiModel.available) {
        if (await _isInstalled(model)) installed.add(model.id);
        final status = await _bridge.query(model);
        statuses[model.id] = status;
        final finished = await _localAiDownloadReadyToVerify(model, status);
        if (finished && !installed.contains(model.id)) {
          if (mounted) setState(() => _verifying.add(model.id));
          try {
            await _verifyCompletedLocalAiDownload(model);
            // 文件已经校验通过，就让系统下载服务停下，别再无谓重试。
            await _bridge.cancel(model);
            installed.add(model.id);
            if (mounted) {
              setState(() => _notice = '${model.name} 下载完成，校验通过，可以离线使用了。');
            }
          } catch (e) {
            await _bridge.cancel(model);
            final retried = _redownloads[model.id] ?? 0;
            if (retried < 1) {
              _redownloads[model.id] = retried + 1;
              if (mounted) {
                setState(() => _error = '${model.name}：$e 正在自动重新下载一次。');
              }
              await _bridge.start(model, useMirror: _useMirror);
            } else if (mounted) {
              setState(() => _error = '${model.name}：$e');
            }
          } finally {
            _verifying.remove(model.id);
          }
        }
      }
      if (mounted) {
        setState(() {
          _statuses
            ..clear()
            ..addAll(statuses);
          _installed
            ..clear()
            ..addAll(installed);
        });
      }
    } catch (e) {
      if (mounted) setState(() => _error = '读取下载状态失败：$e');
    } finally {
      _refreshing = false;
    }
  }

  Future<void> _start(LocalAiModel model) async {
    if (_changing.contains(model.id)) return;
    setState(() {
      _changing.add(model.id);
      _error = null;
      _notice = null;
    });
    try {
      await _bridge.start(model, useMirror: _useMirror);
      await _refresh();
    } catch (e) {
      if (mounted) setState(() => _error = '下载没能开始：$e');
    } finally {
      if (mounted) setState(() => _changing.remove(model.id));
    }
  }

  Future<void> _cancel(LocalAiModel model) async {
    setState(() => _changing.add(model.id));
    try {
      await _bridge.cancel(model);
      await _refresh();
    } catch (e) {
      if (mounted) setState(() => _error = '取消下载失败：$e');
    } finally {
      if (mounted) setState(() => _changing.remove(model.id));
    }
  }

  Future<void> _delete(LocalAiModel model, LedgerBook book) async {
    if (_changing.contains(model.id)) return;
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('删除这个模型？'),
        content: const Text('删除后要重新下载才能离线问答。账单数据不会受影响。'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('先不删'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, true),
            child: const Text('删除'),
          ),
        ],
      ),
    );
    if (confirmed != true || !mounted) return;
    if (_localAiEngineBusy) {
      setState(() => _error = '千问正在回答或整理账单，请稍后再删除。');
      return;
    }
    setState(() => _changing.add(model.id));
    try {
      if (book.settings.localAiModelId == model.id &&
          book.settings.autoAiCaptureEnabled) {
        await ref
            .read(ledgerControllerProvider.notifier)
            .updateSettings(
              book.settings.copyWith(autoAiCaptureEnabled: false),
            );
      }
      await LocalAiEngine.release();
      await _bridge.cancel(model);
      await _deleteLocalAiModelFiles(model);
      _redownloads.remove(model.id);
      if (mounted) setState(() => _notice = '${model.name} 已删除。');
      await _refresh();
    } catch (e) {
      if (mounted) setState(() => _error = '删除失败：$e');
    } finally {
      if (mounted) setState(() => _changing.remove(model.id));
    }
  }

  Future<void> _select(LocalAiModel model, LedgerBook book) async {
    if (book.settings.localAiModelId == model.id) return;
    setState(() => _changing.add(model.id));
    try {
      await ref
          .read(ledgerControllerProvider.notifier)
          .updateSettings(
            book.settings.copyWith(
              localAiModelId: model.id,
              autoAiCaptureEnabled: _installed.contains(model.id)
                  ? book.settings.autoAiCaptureEnabled
                  : false,
            ),
          );
      if (ref.read(ledgerControllerProvider).book?.settings.localAiModelId !=
          model.id) {
        throw const FileSystemException('模型没有保存成功');
      }
    } catch (e) {
      if (mounted) setState(() => _error = '切换模型失败：$e');
    } finally {
      if (mounted) setState(() => _changing.remove(model.id));
    }
  }

  @override
  Widget build(BuildContext context) {
    ref.listen<LedgerViewState>(ledgerControllerProvider, (_, state) {
      if (state.locked && mounted && Navigator.of(context).canPop()) {
        WidgetsBinding.instance.addPostFrameCallback((_) {
          if (mounted) Navigator.of(context).pop();
        });
      }
    });
    final book = ref.watch(ledgerControllerProvider).book;
    if (book == null) {
      return const Scaffold(body: Center(child: Text('账本已锁定，请重新解锁。')));
    }
    final selected = _selectedLocalAiModel(book.settings);
    return Scaffold(
      appBar: AppBar(title: const Text('离线千问（本地 AI）')),
      body: ListView(
        padding: const EdgeInsets.fromLTRB(18, 12, 18, 36),
        children: [
          _GlassCard(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const Text(
                  '选一个版本，点“下载”。下载交给手机系统，退出应用或锁屏都会继续；'
                  '下完会自动校验，校验通过才能使用。',
                  style: TextStyle(height: 1.6),
                ),
                if (!_runnable)
                  Padding(
                    padding: const EdgeInsets.only(top: 8),
                    child: Text(
                      LocalAiCapability.unavailableMessage,
                      style: const TextStyle(
                        color: Colors.deepOrange,
                        height: 1.5,
                      ),
                    ),
                  )
                else if (localAiDeviceNotice.isNotEmpty)
                  Padding(
                    padding: const EdgeInsets.only(top: 8),
                    child: Text(
                      localAiDeviceNotice,
                      style: const TextStyle(
                        color: Colors.deepOrange,
                        height: 1.5,
                      ),
                    ),
                  ),
              ],
            ),
          ),
          const SizedBox(height: 12),
          LocalAiSelfCheckCard(book: book),
          const SizedBox(height: 12),
          _GlassCard(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const Text(
                  '下载地址',
                  style: TextStyle(fontWeight: FontWeight.w700),
                ),
                const SizedBox(height: 8),
                Wrap(
                  spacing: 8,
                  children: [
                    ChoiceChip(
                      label: const Text('官方地址（推荐）'),
                      selected: !_useMirror,
                      onSelected: (_) => setState(() => _useMirror = false),
                    ),
                    ChoiceChip(
                      label: const Text('国内镜像（更快）'),
                      selected: _useMirror,
                      onSelected: (_) => setState(() => _useMirror = true),
                    ),
                  ],
                ),
                const SizedBox(height: 6),
                const Text(
                  '如果一直失败，换个地址再试。下载中断时系统会自动重试，'
                  '必要时也会自动换用备用地址。',
                  style: TextStyle(
                    fontSize: 12,
                    color: Color(0xFF7A869C),
                    height: 1.5,
                  ),
                ),
              ],
            ),
          ),
          if (_error != null)
            Padding(
              padding: const EdgeInsets.only(top: 10),
              child: Text(_error!, style: const TextStyle(color: Colors.red)),
            ),
          if (_notice != null)
            Padding(
              padding: const EdgeInsets.only(top: 10),
              child: Text(
                _notice!,
                style: const TextStyle(color: Color(0xFF0B8457)),
              ),
            ),
          const SizedBox(height: 6),
          for (final model in LocalAiModel.available)
            Padding(
              padding: const EdgeInsets.only(top: 12),
              child: _modelCard(model, book, selected),
            ),
          const SizedBox(height: 16),
          _GlassCard(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const Text(
                  '通知自动记账：全部交给千问',
                  style: TextStyle(fontWeight: FontWeight.w700),
                ),
                const SizedBox(height: 6),
                Text(
                  _installed.contains(selected.id)
                      ? '每一条支付通知都会由千问生成账单；没跑上模型的会留在队列里等，不会被规则猜一个分类。'
                      : '先在上面下载并选中一个模型；在此之前通知会排队等待，不会漏掉。',
                  style: const TextStyle(
                    fontSize: 12,
                    color: Color(0xFF7A869C),
                    height: 1.5,
                  ),
                ),
                const SizedBox(height: 14),
                const Text(
                  '风格要求（可选）',
                  style: TextStyle(fontWeight: FontWeight.w700),
                ),
                const SizedBox(height: 4),
                const Text(
                  '分类和标签请继续用「自定义分类规则」设置，千问会照它执行；'
                  '这里只补充标题、商户怎么写这类风格要求。',
                  style: TextStyle(
                    fontSize: 12,
                    color: Color(0xFF7A869C),
                    height: 1.5,
                  ),
                ),
                const SizedBox(height: 8),
                TextFormField(
                  key: ValueKey(_specController.text.hashCode),
                  controller: _specController,
                  maxLines: 3,
                  decoration: const InputDecoration(
                    hintText: '例如：标题写成"商家 + 用途"；商户写品牌名；'
                        '标签最多 2 个短词。',
                    border: OutlineInputBorder(),
                  ),
                ),
                const SizedBox(height: 8),
                Row(
                  children: [
                    FilledButton(
                      onPressed: _savingSpec
                          ? null
                          : () async {
                              setState(() => _savingSpec = true);
                              await ref
                                  .read(ledgerControllerProvider.notifier)
                                  .updateSettings(
                                    book.settings.copyWith(
                                      aiCaptureSpec: _specController.text.trim(),
                                    ),
                                  );
                              if (mounted) {
                                setState(() => _savingSpec = false);
                              }
                            },
                      child: Text(_savingSpec ? '保存中…' : '保存规范'),
                    ),
                    const SizedBox(width: 8),
                    TextButton(
                      onPressed: () {
                        _specController.text = defaultAiCaptureSpec;
                        setState(() {});
                      },
                      child: const Text('恢复默认'),
                    ),
                  ],
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _modelCard(LocalAiModel model, LedgerBook book, LocalAiModel selected) {
    final status = _statuses[model.id] ?? LocalAiDownloadStatus.idle;
    final installed = _installed.contains(model.id);
    final verifying = _verifying.contains(model.id);
    final busy = _changing.contains(model.id);
    return _GlassCard(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          ListTile(
            contentPadding: EdgeInsets.zero,
            leading: Icon(
              selected.id == model.id
                  ? Icons.radio_button_checked
                  : Icons.radio_button_unchecked,
              color: const Color(0xFF5C6BC0),
            ),
            title: Text(model.name),
            subtitle: Text('${model.sizeLabel} · ${model.description}'),
            trailing: installed
                ? const Icon(
                    Icons.check_circle_rounded,
                    color: Color(0xFF0B8457),
                  )
                : null,
            onTap: _changing.isEmpty ? () => _select(model, book) : null,
          ),
          Text(
            verifying
                ? '正在校验文件，校验通过才能使用…'
                : installed
                ? '已装好，可以离线问答，也能帮忙分类通知'
                : status.chineseStatus,
            style: TextStyle(
              color: installed ? const Color(0xFF0B8457) : null,
            ),
          ),
          if (status.isActive) ...[
            const SizedBox(height: 8),
            LinearProgressIndicator(
              value: status.progress,
              semanticsLabel: '${model.name}下载进度',
            ),
            const SizedBox(height: 4),
            Text(status.sizeText, style: const TextStyle(fontSize: 12)),
          ],
          const SizedBox(height: 10),
          Wrap(
            spacing: 8,
            runSpacing: 8,
            children: [
              if (!installed && !status.isActive && !verifying)
                FilledButton.icon(
                  onPressed: busy || !_runnable ? null : () => _start(model),
                  icon: const Icon(Icons.download_rounded),
                  label: Text(status.state == 'failed' ? '重新下载' : '下载'),
                ),
              if (status.isActive)
                OutlinedButton(
                  onPressed: busy ? null : () => _cancel(model),
                  child: const Text('暂停下载'),
                ),
              if (installed)
                TextButton.icon(
                  onPressed: busy ? null : () => _delete(model, book),
                  icon: const Icon(Icons.delete_outline_rounded),
                  label: const Text('删除'),
                ),
              if (status.state == 'failed' && !installed)
                TextButton(
                  onPressed: busy ? null : () => _cancel(model),
                  child: const Text('清除记录'),
                ),
            ],
          ),
        ],
      ),
    );
  }
}
/// AI 自检：一眼看清卡在哪一步（手机处理器 / 推理库 / 模型 / 真跑一次）。
class LocalAiSelfCheckCard extends ConsumerStatefulWidget {
  const LocalAiSelfCheckCard({required this.book, super.key});

  final LedgerBook book;

  @override
  ConsumerState<LocalAiSelfCheckCard> createState() =>
      _LocalAiSelfCheckCardState();
}

class _LocalAiSelfCheckCardState extends ConsumerState<LocalAiSelfCheckCard> {
  bool? _nativeOk;
  bool _checkingNative = false;
  bool _testing = false;
  bool _installed = false;
  String? _testResult;

  @override
  void initState() {
    super.initState();
    unawaited(_checkNative());
    unawaited(_checkInstalled());
  }

  Future<void> _checkNative() async {
    if (_checkingNative) return;
    _checkingNative = true;
    final ok = await LocalAiCapability.canRun();
    if (mounted) {
      setState(() {
        _nativeOk = ok;
        _checkingNative = false;
      });
    } else {
      _checkingNative = false;
    }
  }

  Future<void> _checkInstalled() async {
    final model = _selectedLocalAiModel(widget.book.settings);
    final installed = await _isInstalled(model);
    if (mounted) setState(() => _installed = installed);
  }

  Future<void> _runTest() async {
    if (_testing) return;
    setState(() {
      _testing = true;
      _testResult = null;
    });
    final model = _selectedLocalAiModel(widget.book.settings);
    final result = await runLocalAiSelfTest(model);
    if (mounted) {
      setState(() {
        _testing = false;
        _testResult = result;
      });
    }
  }

  Widget _row(BuildContext context, String label, String value, {Color? color}) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 6),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          SizedBox(
            width: 84,
            child: Text(
              label,
              style: const TextStyle(fontSize: 13, color: Color(0xFF7A869C)),
            ),
          ),
          Expanded(
            child: Text(
              value,
              style: TextStyle(fontSize: 13, color: color, height: 1.4),
            ),
          ),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final model = _selectedLocalAiModel(widget.book.settings);
    final nativeText = _nativeOk == null
        ? '检测中…'
        : (_nativeOk! ? '可以加载' : '加载失败（这台设备跑不了推理库）');
    return _GlassCard(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Row(
            children: [
              Icon(Icons.fact_check_outlined, color: Color(0xFF5C6BC0)),
              SizedBox(width: 8),
              Text('AI 自检', style: TextStyle(fontWeight: FontWeight.w700)),
            ],
          ),
          const SizedBox(height: 10),
          _row(context, '手机处理器', localAiCpuLabel),
          _row(
            context,
            '推理库',
            nativeText,
            color: _nativeOk == false ? const Color(0xFFE65100) : null,
          ),
          _row(
            context,
            '模型文件',
            _installed ? '已装好：${model.name}' : '尚未下载或未通过校验',
          ),
          if (_testResult != null)
            Padding(
              padding: const EdgeInsets.only(top: 4, bottom: 4),
              child: Text(
                _testResult!,
                style: const TextStyle(fontSize: 13, height: 1.4),
              ),
            ),
          const SizedBox(height: 4),
          Wrap(
            spacing: 8,
            children: [
              FilledButton.icon(
                onPressed: _testing ? null : _runTest,
                icon: _testing
                    ? const SizedBox(
                        width: 14,
                        height: 14,
                        child: CircularProgressIndicator(strokeWidth: 2),
                      )
                    : const Icon(Icons.play_arrow_rounded),
                label: Text(_testing ? '正在试跑…' : '试跑一次'),
              ),
              TextButton(
                onPressed: () {
                  unawaited(_checkNative());
                  unawaited(_checkInstalled());
                },
                child: const Text('重新检测'),
              ),
            ],
          ),
          const Text(
            '如果这里显示"加载失败"或处理器是 32 位，说明这台手机跑不了本机 AI；'
            '把这一屏截图发出来就能定位问题。',
            style: TextStyle(fontSize: 12, color: Color(0xFF7A869C), height: 1.5),
          ),
        ],
      ),
    );
  }
}
