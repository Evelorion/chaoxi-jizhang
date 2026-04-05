import 'dart:io';

void main() async {
  final file = File('lib/src/app.dart');
  var text = await file.readAsString();

  // 1. Add Custom Rules to LedgerBook.empty
  final newEmptyRules = '''
      assetAccounts: const [],
      customRules: [
        CategorizationRule(id: _uuid.v4(), pattern: '瑞幸', categoryId: 'food', autoTags: ['下午茶', '咖啡']),
        CategorizationRule(id: _uuid.v4(), pattern: '喜茶', categoryId: 'food', autoTags: ['下午茶', '奶茶']),
        CategorizationRule(id: _uuid.v4(), pattern: '星巴克', categoryId: 'food', autoTags: ['下午茶', '咖啡']),
        CategorizationRule(id: _uuid.v4(), pattern: '淘宝', categoryId: 'shopping', autoTags: []),
        CategorizationRule(id: _uuid.v4(), pattern: '饿了么', categoryId: 'food', autoTags: ['外卖']),
        CategorizationRule(id: _uuid.v4(), pattern: '滴滴', categoryId: 'mobility', autoTags: ['打车']),
      ],
      settings: VaultSettings(
''';
  text = text.replaceFirst('      assetAccounts: const [],\n      customRules: const [],\n      settings: VaultSettings(', newEmptyRules);

  // 1b. Add Custom Rules to LedgerBook.seeded
  final newSeededRules = '''
    return LedgerBook(
      createdAt: now,
      updatedAt: now,
      entries: entries,
      periods: const [],
      budgets: budgets,
      goals: goals,
      subscriptions: subscriptions,
      assetAccounts: const [],
      customRules: [
        CategorizationRule(id: _uuid.v4(), pattern: '瑞幸', categoryId: 'food', autoTags: ['下午茶', '咖啡']),
        CategorizationRule(id: _uuid.v4(), pattern: '喜茶', categoryId: 'food', autoTags: ['下午茶', '奶茶']),
        CategorizationRule(id: _uuid.v4(), pattern: '星巴克', categoryId: 'food', autoTags: ['下午茶', '咖啡']),
        CategorizationRule(id: _uuid.v4(), pattern: '美团', categoryId: 'food', autoTags: ['外卖']),
        CategorizationRule(id: _uuid.v4(), pattern: '滴滴', categoryId: 'mobility', autoTags: ['打车']),
      ],
      settings: VaultSettings(
''';
  text = text.replaceFirst('    return LedgerBook(\n      createdAt: now,\n      updatedAt: now,\n      entries: entries,\n      periods: const [],\n      budgets: budgets,\n      goals: goals,\n      subscriptions: subscriptions,\n      settings: VaultSettings(', newSeededRules);

  // 2. Add AssetAccountsCard to DashboardScreen
  final targetDashboardSection = "              const SizedBox(height: 22),\n              _SectionHeader(title: '近六个月现金流', actionLabel: '', onTap: null),";
  final dashboardInjection = "              const SizedBox(height: 22),\n              _SectionHeader(title: '目前我的资产', actionLabel: '管理', onTap: () => pushPremiumPage<void>(context, page: AssetAccountsView(book: book))),\n              const SizedBox(height: 12),\n              AssetAccountsCard(book: book, viewState: viewState),\n" + targetDashboardSection;
  text = text.replaceFirst(targetDashboardSection, dashboardInjection);

  await file.writeAsString(text);

  // 3. Create AssetAccountsCard in ui_extensions.dart
  final uiFile = File('lib/src/ui_extensions.dart');
  var uiText = await uiFile.readAsString();

  final assetCardCode = '''
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
                '￥\${calculatedBalance.toStringAsFixed(2)}',
                style: GoogleFonts.spaceGrotesk(fontSize: 18, fontWeight: FontWeight.bold, color: const Color(0xFF1B2436)),
              ),
            ),
          ),
        );
      }).toList(),
    );
  }
}
''';

  if (!uiText.contains('class AssetAccountsCard')) {
    uiText = uiText + '\n\n' + assetCardCode;
    await uiFile.writeAsString(uiText);
  }
}
