import 'dart:io';

void main() async {
  final file = File('lib/src/app.dart');
  var text = await file.readAsString();

  // 1. _captureToEntry
  text = text.replaceFirst('LedgerEntry _captureToEntry(AutoCaptureRecord capture, LedgerBook book) {\n    final resolvedCategoryId = inferAutoCaptureCategoryId(\n      book: book,\n      capture: capture,\n    );', 'LedgerEntry _captureToEntry(AutoCaptureRecord capture, LedgerBook book) {\n    final inferred = inferAutoCaptureCategoryId(\n      book: book,\n      capture: capture,\n    );\n    final resolvedCategoryId = inferred.\$1;\n    final customTags = inferred.\$2;');
  text = text.replaceFirst("tags: [\n        ...sourceTags,\n        scenarioLabel,\n        if (capture.confidence >= 0.85) '高置信度',\n      ]", "tags: [\n        ...sourceTags,\n        scenarioLabel,\n        ...customTags,\n        if (capture.confidence >= 0.85) '高置信度',\n      ]");

  // 2. inferAutoCaptureCategoryId
  text = text.replaceFirst("String inferAutoCaptureCategoryId({", "(String, List<String>) inferAutoCaptureCategoryId({");
  text = text.replaceFirst("final categories = categoriesForType(capture.entryType);", "for (final rule in book.customRules) {\n    if (rule.pattern.isNotEmpty && lowercase.contains(rule.pattern.toLowerCase())) {\n      return (rule.categoryId, rule.autoTags);\n    }\n  }\n  final categories = categoriesForType(capture.entryType);");
  text = text.replaceFirst("return 'family';", "return ('family', const <String>[]);");
  text = text.replaceFirst("return keywordMatch.id;", "return (keywordMatch.id, const <String>[]);");
  text = text.replaceFirst("return 'shopping';", "return ('shopping', const <String>[]);");
  text = text.replaceFirst("return capture.defaultCategoryId;", "return (capture.defaultCategoryId, const <String>[]);");
  text = text.replaceFirst("return resolveDefaultExpenseCategoryId(book.settings);", "return (resolveDefaultExpenseCategoryId(book.settings), const <String>[]);");
  text = text.replaceFirst("return incomeKeywordMatch.id;", "return (incomeKeywordMatch.id, const <String>[]);");
  text = text.replaceFirst("return 'salary';", "return ('salary', const <String>[]);");

  // 3. _syncCaptures
  final linkFn = '''
  void _linkRefundBindings(List<LedgerEntry> entries) {
    final linkedRefundIds = <String>{};
    for (final e in entries) linkedRefundIds.addAll(e.linkedRefundEntryIds);
    final refundEntries = entries.where((e) => e.type == EntryType.income && (e.tags.contains('退款') || e.tags.contains('平台退款') || e.sourceLabel.contains('退款') || e.title.contains('退款') || e.categoryId == 'refund')).toList();
    for (final refund in refundEntries) {
      if (linkedRefundIds.contains(refund.id)) continue;
      final candidateIndex = entries.indexWhere((expense) {
        if (expense.type != EntryType.expense) return false;
        if ((expense.amount - refund.amount).abs() > 0.009) return false;
        if (expense.occurredAt.isAfter(refund.occurredAt)) return false;
        if (refund.occurredAt.difference(expense.occurredAt).inDays > 90) return false;
        if (expense.merchant.isNotEmpty && expense.merchant == refund.merchant) return !expense.linkedRefundEntryIds.contains(refund.id);
        if (expense.counterpartyName.isNotEmpty && expense.counterpartyName == refund.counterpartyName) return !expense.linkedRefundEntryIds.contains(refund.id);
        if (expense.sourceLabel == refund.sourceLabel) return !expense.linkedRefundEntryIds.contains(refund.id);
        return false;
      });
      if (candidateIndex != -1) {
        final target = entries[candidateIndex];
        entries[candidateIndex] = target.copyWith(linkedRefundEntryIds: [...target.linkedRefundEntryIds, refund.id]);
        linkedRefundIds.add(refund.id);
      }
    }
  }

  Future<void> importEncryptedBackupFromFile(''';
  text = text.replaceFirst('  Future<void> importEncryptedBackupFromFile(', linkFn);
  text = text.replaceFirst('    final updatedBook = book.copyWith(\n      entries: [...workingEntries]', '    _linkRefundBindings(workingEntries);\n    final updatedBook = book.copyWith(\n      entries: [...workingEntries]');

  // 4. tags UI
  final tagUi = '''
                  if (entry.tags.isNotEmpty || entry.linkedRefundEntryIds.isNotEmpty || entry.locationInfo.isNotEmpty) ...[
                    const SizedBox(height: 8),
                    Wrap(
                      crossAxisAlignment: WrapCrossAlignment.center,
                      spacing: 6,
                      runSpacing: 6,
                      children: [
                        if (entry.locationInfo.isNotEmpty)
                          Container(
                            padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 3),
                            decoration: BoxDecoration(color: const Color(0xFFE8EAF6), borderRadius: BorderRadius.circular(6)),
                            child: Row(
                              mainAxisSize: MainAxisSize.min,
                              children: [
                                const Icon(Icons.location_on, size: 11, color: Color(0xFF5C6BC0)),
                                const SizedBox(width: 2),
                                Text(entry.locationInfo, style: GoogleFonts.plusJakartaSans(fontSize: 11, fontWeight: FontWeight.w600, color: const Color(0xFF5C6BC0))),
                              ],
                            ),
                          ),
                        if (entry.linkedRefundEntryIds.isNotEmpty && viewState.book != null)
                          Builder(builder: (context) {
                            final refundAmount = entry.linkedRefundEntryIds.map((id) => viewState.book!.entries.where((e) => e.id == id).firstOrNull?.amount ?? 0.0).fold<double>(0.0, (a, b) => a + b);
                            return Container(
                              padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 3),
                              decoration: BoxDecoration(color: const Color(0xFFEBF8EE), borderRadius: BorderRadius.circular(6)),
                              child: Text('已关联退款 +￥\${refundAmount.toStringAsFixed(2)}', style: GoogleFonts.plusJakartaSans(fontSize: 11, fontWeight: FontWeight.w600, color: const Color(0xFF11A66A))),
                            );
                          }),
                        ...entry.tags.take(3).map(
''';
  text = text.replaceFirst('                  if (entry.tags.isNotEmpty) ...[\n                    const SizedBox(height: 8),\n                    Wrap(\n                      spacing: 6,\n                      runSpacing: 6,\n                      children: entry.tags\n                          .take(3)\n                          .map(', tagUi);
  text = text.replaceFirst('.toList(),\n                    ),', ').toList(),\n                      ],\n                    ),');

  // 5. VaultScreen Vault UI
  final vaultUi = '''
              ),
              const SizedBox(height: 22),
              _SectionHeader(
                title: '空间与资产自动化',
                actionLabel: '',
                onTap: () {},
              ),
              const SizedBox(height: 12),
              _GlassCard(
                child: Column(
                  children: [
                    DropdownButtonFormField<LocationTrackingMode>(
                      value: book.settings.locationMode,
                      decoration: const InputDecoration(labelText: '位置记账助手模式'),
                      items: const [
                        DropdownMenuItem(value: LocationTrackingMode.off, child: Text('关闭位置记录')),
                        DropdownMenuItem(value: LocationTrackingMode.foregroundLazy, child: Text('前台懒加载模式 (推荐)')),
                        DropdownMenuItem(value: LocationTrackingMode.ipRough, child: Text('网络 IP 粗略定位')),
                        DropdownMenuItem(value: LocationTrackingMode.backgroundPrecise, child: Text('后台精确定位 (可能耗电)')),
                      ],
                      onChanged: (value) {
                        if (value == null) return;
                        controller.updateSettings(book.settings.copyWith(locationMode: value));
                      },
                    ),
                    const SizedBox(height: 12),
                    ListTile(
                      contentPadding: EdgeInsets.zero,
                      leading: Container(
                        padding: const EdgeInsets.all(8),
                        decoration: BoxDecoration(color: const Color(0xFFE8EAF6), borderRadius: BorderRadius.circular(8)),
                        child: const Icon(Icons.rule, color: Color(0xFF5C6BC0), size: 20),
                      ),
                      title: const Text('自定义分类规则'),
                      subtitle: Text('已配置 \${book.customRules.length} 条规则'),
                      trailing: const Icon(Icons.chevron_right),
                      onTap: () => pushPremiumPage<void>(context, page: SettingsCustomRulesView(book: book)),
                    ),
                    const SizedBox(height: 12),
                    ListTile(
                      contentPadding: EdgeInsets.zero,
                      leading: Container(
                        padding: const EdgeInsets.all(8),
                        decoration: BoxDecoration(color: const Color(0xFFE8EAF6), borderRadius: BorderRadius.circular(8)),
                        child: const Icon(Icons.account_balance_wallet, color: Color(0xFF5C6BC0), size: 20),
                      ),
                      title: const Text('资金账户池'),
                      subtitle: Text('已绑定 \${book.assetAccounts.length} 个期初资产'),
                      trailing: const Icon(Icons.chevron_right),
                      onTap: () => pushPremiumPage<void>(context, page: AssetAccountsView(book: book)),
                    ),
                  ],
                ),
              ),
''';
  text = text.replaceFirst("              const SizedBox(height: 22),\n              _SectionHeader(\n                title: '备份与隐私',", "\$vaultUi\n              const SizedBox(height: 22),\n              _SectionHeader(\n                title: '备份与隐私',");

  text = text.replaceFirst("                  child: _PillarTile(pillar: pillar, state: viewState),\n                ),\n            ],\n          ),\n        ),\n      ],\n    );", "                  child: _PillarTile(pillar: pillar, state: viewState),\n                ),\n              const SizedBox(height: 24),\n              HeatmapView(book: book),\n              const SizedBox(height: 24),\n              SankeyView(book: book),\n            ],\n          ),\n        ),\n      ],\n    );");


  await file.writeAsString(text);
}
