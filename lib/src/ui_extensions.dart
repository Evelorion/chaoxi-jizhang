part of 'app.dart';

class SettingsCustomRulesView extends ConsumerStatefulWidget {
  const SettingsCustomRulesView({required this.book, super.key});
  final LedgerBook book;

  @override
  ConsumerState<SettingsCustomRulesView> createState() => _SettingsCustomRulesViewState();
}

class _SettingsCustomRulesViewState extends ConsumerState<SettingsCustomRulesView> {
  late List<CategorizationRule> _rules;

  @override
  void initState() {
    super.initState();
    _rules = List.from(widget.book.customRules);
  }

  void _save() {
    final book = widget.book.copyWith(customRules: _rules);
    ref.read(ledgerControllerProvider.notifier).updateBook(book);
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(content: Text('已保存自定义分类规则'), behavior: SnackBarBehavior.floating),
    );
  }

  void _addRule() async {
    final newRule = await showModalBottomSheet<CategorizationRule>(
      context: context,
      isScrollControlled: true,
      builder: (_) => const _RuleEditorSheet(),
    );
    if (newRule != null) {
      setState(() { _rules.add(newRule); });
      _save();
    }
  }

  void _deleteRule(int index) {
    setState(() { _rules.removeAt(index); });
    _save();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: const Color(0xFFF9FAFC),
      appBar: AppBar(
        title: const Text('自定义分类规则'),
        backgroundColor: Colors.transparent,
      ),
      body: _rules.isEmpty
          ? Center(
              child: Padding(
                padding: const EdgeInsets.all(32),
                child: Text(
                  '你还没有配置任何规则。\\n\\n配置规则后，当自动记账时如果遇到包含你设定关键词的商户或商品，将优先使用你设定的分类和标签。',
                  style: GoogleFonts.plusJakartaSans(color: const Color(0xFF60708A), height: 1.5),
                  textAlign: TextAlign.center,
                ),
              ),
            )
          : ListView.builder(
              padding: const EdgeInsets.all(20),
              itemCount: _rules.length,
              itemBuilder: (context, index) {
                final rule = _rules[index];
                final category = categoryForId(rule.categoryId);
                return _GlassCard(
                  child: ListTile(
                    contentPadding: EdgeInsets.zero,
                    leading: Container(
                      width: 40, height: 40,
                      decoration: BoxDecoration(
                        color: category.color.withValues(alpha: 0.14),
                        borderRadius: BorderRadius.circular(12),
                      ),
                      child: Icon(category.icon, color: category.color, size: 20),
                    ),
                    title: Text('包含: ${rule.pattern}'),
                    subtitle: Text("分类为: ${category.name}\n自动打标: ${rule.autoTags.join(', ')}"),
                    isThreeLine: rule.autoTags.isNotEmpty,
                    trailing: IconButton(
                      icon: const Icon(Icons.delete_outline, color: Color(0xFFC44536)),
                      onPressed: () => _deleteRule(index),
                    ),
                  ),
                );
              },
            ),
      floatingActionButton: FloatingActionButton.extended(
        onPressed: _addRule,
        icon: const Icon(Icons.add),
        label: const Text('新建规则'),
      ),
    );
  }
}

class _RuleEditorSheet extends StatefulWidget {
  const _RuleEditorSheet();
  @override
  State<_RuleEditorSheet> createState() => _RuleEditorSheetState();
}

class _RuleEditorSheetState extends State<_RuleEditorSheet> {
  final _patternCtrl = TextEditingController();
  final _tagsCtrl = TextEditingController();
  String _categoryId = 'food';

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: EdgeInsets.only(
        left: 20, right: 20, top: 20,
        bottom: MediaQuery.of(context).viewInsets.bottom + 20,
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Text('新建规则', style: GoogleFonts.spaceGrotesk(fontSize: 20, fontWeight: FontWeight.w700)),
          const SizedBox(height: 16),
          TextField(
            controller: _patternCtrl,
            decoration: const InputDecoration(labelText: '匹配关键词 (如: 瑞幸)', border: OutlineInputBorder()),
          ),
          const SizedBox(height: 12),
          DropdownButtonFormField<String>(
            value: _categoryId,
            decoration: const InputDecoration(labelText: '归入分类', border: OutlineInputBorder()),
            items: categoriesForType(EntryType.expense).map((cat) => DropdownMenuItem(value: cat.id, child: Text(cat.name))).toList(),
            onChanged: (v) => setState(() => _categoryId = v!),
          ),
          const SizedBox(height: 12),
          TextField(
            controller: _tagsCtrl,
            decoration: const InputDecoration(labelText: '自动打标 (多个请用逗号隔开)', border: OutlineInputBorder()),
          ),
          const SizedBox(height: 24),
          FilledButton(
            onPressed: () {
              if (_patternCtrl.text.trim().isEmpty) return;
              final rule = CategorizationRule(
                id: const Uuid().v4(),
                pattern: _patternCtrl.text.trim(),
                categoryId: _categoryId,
                autoTags: _tagsCtrl.text.split(',').map((e) => e.trim()).where((e) => e.isNotEmpty).toList(),
              );
              Navigator.of(context).pop(rule);
            },
            child: const Text('保存'),
          ),
        ],
      ),
    );
  }
}

class AssetAccountsView extends ConsumerStatefulWidget {
  const AssetAccountsView({required this.book, super.key});
  final LedgerBook book;

  @override
  ConsumerState<AssetAccountsView> createState() => _AssetAccountsViewState();
}

class _AssetAccountsViewState extends ConsumerState<AssetAccountsView> {
  late List<AssetAccount> _accounts;

  @override
  void initState() {
    super.initState();
    _accounts = List.from(widget.book.assetAccounts);
  }

  void _save() {
    final book = widget.book.copyWith(assetAccounts: _accounts);
    ref.read(ledgerControllerProvider.notifier).updateBook(book);
  }

  void _editAccount(int index, AssetAccount acc) async {
    final updatedAcc = await showModalBottomSheet<AssetAccount>(
      context: context,
      isScrollControlled: true,
      builder: (_) => _AssetEditorSheet(initialAccount: acc),
    );
    if (updatedAcc != null) {
      setState(() => _accounts[index] = updatedAcc);
      Future.delayed(const Duration(milliseconds: 300), _save);
    }
  }

  void _addAccount() async {
    final newAcc = await showModalBottomSheet<AssetAccount>(
      context: context,
      isScrollControlled: true,
      builder: (_) => const _AssetEditorSheet(),
    );
    if (newAcc != null) {
      setState(() => _accounts.add(newAcc));
      Future.delayed(const Duration(milliseconds: 300), _save);
    }
  }

  void _deleteAccount(int index) {
    setState(() => _accounts.removeAt(index));
    _save();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: const Color(0xFFF9FAFC),
      appBar: AppBar(title: const Text('资产账户池'), backgroundColor: Colors.transparent),
      body: _accounts.isEmpty
          ? Center(
              child: Padding(
                padding: const EdgeInsets.all(32),
                child: Text('快来添加你的微信、支付宝或者银行卡资产吧！\\n\\n添加期初余额后，这里的数字会随着你的流水自动增减，还原你真实的可用资金。', style: GoogleFonts.plusJakartaSans(color: const Color(0xFF60708A), height: 1.5), textAlign: TextAlign.center),
              ),
            )
          : ListView.builder(
              padding: const EdgeInsets.all(20),
              itemCount: _accounts.length,
              itemBuilder: (context, index) {
                final acc = _accounts[index];
                
                PaymentChannel? mappedChannel;
                if (acc.type == AssetType.wechat) mappedChannel = PaymentChannel.wechatPay;
                if (acc.type == AssetType.alipay) mappedChannel = PaymentChannel.alipay;
                if (acc.type == AssetType.bankCard) mappedChannel = PaymentChannel.bankCard;
                
                double calculatedBalance = acc.initialBalance;
                for (final e in widget.book.entries) {
                  if (e.channel == mappedChannel) {
                    if (e.type == EntryType.income) calculatedBalance += e.amount;
                    if (e.type == EntryType.expense) calculatedBalance -= e.amount;
                  }
                }

                return _GlassCard(
                    child: InkWell(
                      onTap: () => _editAccount(index, acc),
                      borderRadius: BorderRadius.circular(16),
                      child: ListTile(
                    contentPadding: EdgeInsets.zero,
                    leading: Container(
                      width: 48, height: 48,
                      decoration: BoxDecoration(color: const Color(0xFFE8EAF6), borderRadius: BorderRadius.circular(12)),
                      child: Icon(
                        acc.type == AssetType.wechat ? Icons.wechat : acc.type == AssetType.alipay ? Icons.local_atm : Icons.account_balance,
                        color: const Color(0xFF5C6BC0)
                      ),
                    ),
                    title: Text(acc.name, style: GoogleFonts.plusJakartaSans(fontWeight: FontWeight.w700)),
                    subtitle: Text('期初: ${acc.initialBalance}', style: GoogleFonts.plusJakartaSans(fontSize: 12)),
                    trailing: Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Text('￥${calculatedBalance.toStringAsFixed(2)}', style: GoogleFonts.spaceGrotesk(fontSize: 18, fontWeight: FontWeight.bold, color: const Color(0xFF1B2436))),
                        IconButton(icon: const Icon(Icons.delete_outline, size: 20, color: Color(0xFFC44536)), onPressed: () => _deleteAccount(index)),
                      ],
                    ),
                    ),
                  ),
                );
              },
            ),
      floatingActionButton: FloatingActionButton.extended(
        onPressed: _addAccount,
        icon: const Icon(Icons.add),
        label: const Text('录入资金池'),
      ),
    );
  }
}

class _AssetEditorSheet extends StatefulWidget {
  const _AssetEditorSheet({this.initialAccount, super.key});
  final AssetAccount? initialAccount;
  @override
  State<_AssetEditorSheet> createState() => _AssetEditorSheetState();
}

class _AssetEditorSheetState extends State<_AssetEditorSheet> {
  late final TextEditingController _nameCtrl = TextEditingController(text: widget.initialAccount?.name ?? '');
  late final TextEditingController _amountCtrl = TextEditingController(text: widget.initialAccount?.initialBalance.toString() ?? '');
  late AssetType _type = widget.initialAccount?.type ?? AssetType.wechat;


  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: EdgeInsets.only(left: 20, right: 20, top: 20, bottom: MediaQuery.of(context).viewInsets.bottom + 20),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Text(widget.initialAccount == null ? '新增资金池' : '修改资金池 (重设起止余额)', style: GoogleFonts.spaceGrotesk(fontSize: 20, fontWeight: FontWeight.w700)),
          const SizedBox(height: 16),
          DropdownButtonFormField<AssetType>(
            value: _type,
            decoration: const InputDecoration(labelText: '资产类型', border: OutlineInputBorder()),
            items: AssetType.values.map((t) => DropdownMenuItem(value: t, child: Text(t.name))).toList(),
            onChanged: (v) => setState(() => _type = v!),
          ),
          const SizedBox(height: 12),
          TextField(controller: _nameCtrl, decoration: const InputDecoration(labelText: '子账户别名 (如: 建设银行尾号1234)', border: OutlineInputBorder())),
          const SizedBox(height: 12),
          TextField(controller: _amountCtrl, decoration: const InputDecoration(labelText: '期初余额', border: OutlineInputBorder()), keyboardType: const TextInputType.numberWithOptions(decimal: true)),
          const SizedBox(height: 24),
          FilledButton(
            onPressed: () {
              final finalName = _nameCtrl.text.trim().isEmpty ? _type.name : _nameCtrl.text.trim();
              final amt = double.tryParse(_amountCtrl.text.trim()) ?? 0.0;
              final acc = AssetAccount(id: widget.initialAccount?.id ?? const Uuid().v4(), name: finalName, type: _type, initialBalance: amt);
              Navigator.of(context).pop(acc);
            },
            child: Text(widget.initialAccount == null ? '确认添加' : '保存修改'),
          ),
        ],
      ),
    );
  }
}

class HeatmapView extends StatelessWidget {
  const HeatmapView({required this.book, super.key});
  final LedgerBook book;

  @override
  Widget build(BuildContext context) {
    if (book.entries.isEmpty) return const SizedBox.shrink();
    
    final now = DateTime.now();
    final today = DateTime(now.year, now.month, now.day);
    final days = <DateTime>[];
    for (int i = 29; i >= 0; i--) {
      days.add(today.subtract(Duration(days: i)));
    }
    
    final spendByDay = <DateTime, double>{};
    for (final e in book.entries) {
      if (e.type != EntryType.expense) continue;
      final eDay = DateTime(e.occurredAt.year, e.occurredAt.month, e.occurredAt.day);
      spendByDay[eDay] = (spendByDay[eDay] ?? 0) + e.amount;
    }
    
    double maxSpend = 1;
    for (final v in spendByDay.values) {
      if (v > maxSpend) maxSpend = v;
    }

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          '近 30 天消费热力图',
          style: GoogleFonts.plusJakartaSans(fontSize: 16, fontWeight: FontWeight.w700),
        ),
        const SizedBox(height: 12),
        Wrap(
          spacing: 6,
          runSpacing: 6,
          children: days.map((day) {
            final spend = spendByDay[day] ?? 0;
            final intensity = (spend / maxSpend).clamp(0.0, 1.0);
            
            Color boxColor = const Color(0xFFE8EAF6);
            if (intensity > 0) {
              boxColor = Color.lerp(const Color(0xFFC5CAE9), const Color(0xFF3949AB), intensity)!;
            }
            
            return Tooltip(
              message: '${day.month}月${day.day}日: ￥${spend.toStringAsFixed(0)}',
              child: Container(
                width: 20, height: 20,
                decoration: BoxDecoration(
                  color: boxColor,
                  borderRadius: BorderRadius.circular(4),
                ),
              ),
            );
          }).toList(),
        ),
      ],
    );
  }
}

class SankeyView extends StatelessWidget {
  const SankeyView({required this.book, super.key});
  final LedgerBook book;

  @override
  Widget build(BuildContext context) {
    if (book.entries.isEmpty) return const SizedBox.shrink();
    
    final channelToCategory = <String, double>{};
    double totalSpend = 0;
    
    for (final e in book.entries) {
      if (e.type != EntryType.expense) continue;
      final key = '${e.channel.label} -> ${categoryForId(e.categoryId).name}';
      channelToCategory[key] = (channelToCategory[key] ?? 0) + e.amount;
      totalSpend += e.amount;
    }
    
    if (totalSpend == 0) return const SizedBox.shrink();

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          '全局流向 (资金渠道 -> 消费类别)',
          style: GoogleFonts.plusJakartaSans(fontSize: 16, fontWeight: FontWeight.w700),
        ),
        const SizedBox(height: 12),
        Container(
          width: double.infinity,
          padding: const EdgeInsets.all(12),
          decoration: BoxDecoration(
            color: const Color(0xFFF9FAFC),
            border: Border.all(color: const Color(0xFFE9EEF8)),
            borderRadius: BorderRadius.circular(16)
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: channelToCategory.entries.take(8).map((entry) {
              final pct = entry.value / totalSpend;
              return Padding(
                padding: const EdgeInsets.only(bottom: 8),
                child: Row(
                  children: [
                    Expanded(
                      flex: 4,
                      child: Text(entry.key, style: const TextStyle(fontSize: 11), maxLines: 1, overflow: TextOverflow.ellipsis),
                    ),
                    Expanded(
                      flex: 6,
                      child: ClipRRect(
                        borderRadius: BorderRadius.circular(4),
                        child: LinearProgressIndicator(
                          value: pct,
                          backgroundColor: const Color(0xFFE9EEF8),
                          color: const Color(0xFF3949AB),
                          minHeight: 8,
                        ),
                      ),
                    ),
                    const SizedBox(width: 8),
                    Text('￥${entry.value.toStringAsFixed(0)}', style: const TextStyle(fontSize: 11, fontWeight: FontWeight.bold)),
                  ],
                ),
              );
            }).toList(),
          ),
        ),
      ],
    );
  }
}


class AssetAccountsCard extends ConsumerWidget {
  const AssetAccountsCard({required this.book, required this.viewState, super.key});
  final LedgerBook book;
  final LedgerViewState viewState;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    if (book.assetAccounts.isEmpty) {
      return _GlassCard(
        child: Padding(
          padding: const EdgeInsets.all(16),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Text('还没录入期初资产', style: GoogleFonts.plusJakartaSans(fontWeight: FontWeight.w700, fontSize: 16)),
              const SizedBox(height: 4),
              Text('快来添加微信、支付宝或银行卡，实时计算你的净资产！', style: GoogleFonts.plusJakartaSans(color: const Color(0xFF60708A), fontSize: 13)),
              const SizedBox(height: 12),
              FilledButton.tonalIcon(
                onPressed: () => pushPremiumPage<void>(context, page: AssetAccountsView(book: book)),
                icon: const Icon(Icons.add),
                label: const Text('录入资金池'),
              ),
            ],
          ),
        ),
      );
    }

    return Column(
      children: book.assetAccounts.take(3).map((acc) {
        PaymentChannel? mappedChannel;
        if (acc.type == AssetType.wechat) mappedChannel = PaymentChannel.wechatPay;
        if (acc.type == AssetType.alipay) mappedChannel = PaymentChannel.alipay;
        if (acc.type == AssetType.bankCard) mappedChannel = PaymentChannel.bankCard;
        
        double calculatedBalance = acc.initialBalance;
        for (final e in book.entries) {
          if (e.channel == mappedChannel) {
            if (e.type == EntryType.income) calculatedBalance += e.amount;
            if (e.type == EntryType.expense) calculatedBalance -= e.amount;
          }
        }
        return Padding(
          padding: const EdgeInsets.only(bottom: 8.0),
          child: _GlassCard(
            child: ListTile(
              contentPadding: EdgeInsets.zero,
              leading: Container(
                width: 48, height: 48,
                decoration: BoxDecoration(color: const Color(0xFFE8EAF6), borderRadius: BorderRadius.circular(12)),
                child: Icon(
                  acc.type == AssetType.wechat ? Icons.wechat : acc.type == AssetType.alipay ? Icons.local_atm : Icons.account_balance,
                  color: const Color(0xFF5C6BC0)
                ),
              ),
              title: Text(acc.name, style: GoogleFonts.plusJakartaSans(fontWeight: FontWeight.w700)),
              trailing: Text(
                '￥${calculatedBalance.toStringAsFixed(2)}',
                style: GoogleFonts.spaceGrotesk(fontSize: 18, fontWeight: FontWeight.bold, color: const Color(0xFF1B2436)),
              ),
            ),
          ),
        );
      }).toList(),
    );
  }
}
