import 'dart:io';

void main() async {
  final file = File('lib/src/app.dart');
  var text = await file.readAsString();
  text = text.replaceAll('\r\n', '\n');

  if (!text.contains("part 'ui_extensions.dart';")) {
    text = text.replaceFirst("import 'package:uuid/uuid.dart';", "import 'package:uuid/uuid.dart';\n\npart 'ui_extensions.dart';");
  }

  if (!text.contains("enum LocationTrackingMode {")) {
    text = text.replaceFirst("class LedgerEntry {", '''
enum LocationTrackingMode { off, foregroundLazy, backgroundPrecise, ipRough }
enum AssetType { wechat, alipay, bankCard, cash, other }

class AssetAccount {
  const AssetAccount({
    required this.id,
    required this.name,
    required this.type,
    required this.initialBalance,
  });

  final String id;
  final String name;
  final AssetType type;
  final double initialBalance;

  Map<String, dynamic> toJson() => {
    'id': id,
    'name': name,
    'type': type.name,
    'initialBalance': initialBalance,
  };

  factory AssetAccount.fromJson(Map<String, dynamic> json) => AssetAccount(
    id: json['id'] as String,
    name: json['name'] as String,
    type: AssetType.values.byName(json['type'] as String),
    initialBalance: (json['initialBalance'] as num).toDouble(),
  );
}

class CategorizationRule {
  const CategorizationRule({
    required this.id,
    required this.pattern,
    required this.categoryId,
    required this.autoTags,
  });

  final String id;
  final String pattern;
  final String categoryId;
  final List<String> autoTags;

  Map<String, dynamic> toJson() => {
    'id': id,
    'pattern': pattern,
    'categoryId': categoryId,
    'autoTags': autoTags,
  };

  factory CategorizationRule.fromJson(Map<String, dynamic> json) => CategorizationRule(
    id: json['id'] as String,
    pattern: json['pattern'] as String,
    categoryId: json['categoryId'] as String,
    autoTags: (json['autoTags'] as List<dynamic>? ?? const []).cast<String>(),
  );
}

class LedgerEntry {''');
  }

  // settings field in vaultsettings
  text = text.replaceAll(RegExp(r'required this\.xianyuEnabled,([^]*?)\}\);'), 'required this.xianyuEnabled,\n    this.locationMode = LocationTrackingMode.off,\n  });');
  text = text.replaceFirst('final bool xianyuEnabled;\n\n  Map<String, dynamic> toJson() => {', 'final bool xianyuEnabled;\n  final LocationTrackingMode locationMode;\n\n  Map<String, dynamic> toJson() => {');
  text = text.replaceFirst("'xianyuEnabled': xianyuEnabled,\n  };", "'xianyuEnabled': xianyuEnabled,\n    'locationMode': locationMode.name,\n  };");
  text = text.replaceFirst("xianyuEnabled: json['xianyuEnabled'] as bool? ?? true,\n  );", "xianyuEnabled: json['xianyuEnabled'] as bool? ?? true,\n    locationMode: LocationTrackingMode.values.firstWhere((e) => e.name == (json['locationMode'] as String?), orElse: () => LocationTrackingMode.off),\n  );");
  text = text.replaceFirst("bool? xianyuEnabled,\n  }) {", "bool? xianyuEnabled,\n    LocationTrackingMode? locationMode,\n  }) {");
  text = text.replaceFirst("xianyuEnabled: xianyuEnabled ?? this.xianyuEnabled,\n    );", "xianyuEnabled: xianyuEnabled ?? this.xianyuEnabled,\n      locationMode: locationMode ?? this.locationMode,\n    );");

  // LedgerBook parameter
  text = text.replaceFirst('required this.settings,\n  });', 'required this.settings,\n    this.assetAccounts = const [],\n    this.customRules = const [],\n  });');
  text = text.replaceFirst('settings: VaultSettings(', 'assetAccounts: const [],\n      customRules: const [],\n      settings: VaultSettings(');
  text = text.replaceFirst('final VaultSettings settings;\n\n  Map<String, dynamic> toJson() => {', 'final VaultSettings settings;\n  final List<AssetAccount> assetAccounts;\n  final List<CategorizationRule> customRules;\n\n  Map<String, dynamic> toJson() => {');
  text = text.replaceFirst("'settings': settings.toJson(),\n  };", "'settings': settings.toJson(),\n    'assetAccounts': assetAccounts.map((e) => e.toJson()).toList(),\n    'customRules': customRules.map((e) => e.toJson()).toList(),\n  };");
  text = text.replaceFirst("VaultSettings.fromJson(\n      Map<String, dynamic>.from(json['settings'] as Map? ?? const {}),\n    ),\n  );", "VaultSettings.fromJson(\n      Map<String, dynamic>.from(json['settings'] as Map? ?? const {}),\n    ),\n    assetAccounts: (json['assetAccounts'] as List<dynamic>? ?? []).map((e) => AssetAccount.fromJson(e as Map<String, dynamic>)).toList(),\n    customRules: (json['customRules'] as List<dynamic>? ?? []).map((e) => CategorizationRule.fromJson(e as Map<String, dynamic>)).toList(),\n  );");
  text = text.replaceFirst("VaultSettings? settings,\n  }) {", "VaultSettings? settings,\n    List<AssetAccount>? assetAccounts,\n    List<CategorizationRule>? customRules,\n  }) {");
  text = text.replaceFirst("settings: settings ?? this.settings,\n    );", "settings: settings ?? this.settings,\n      assetAccounts: assetAccounts ?? this.assetAccounts,\n      customRules: customRules ?? this.customRules,\n    );");

  // LedgerEntry parameter
  text = text.replaceFirst('required this.tags,\n    required this.autoCaptured,', "this.tags = const [],\n    this.linkedRefundEntryIds = const [],\n    this.locationInfo = '',\n    required this.autoCaptured,");
  text = text.replaceFirst('final List<String> tags;\n  final bool autoCaptured;', "final List<String> tags;\n  final List<String> linkedRefundEntryIds;\n  final String locationInfo;\n  final bool autoCaptured;");
  text = text.replaceFirst("List<String>? tags,\n    bool? autoCaptured,", "List<String>? tags,\n    List<String>? linkedRefundEntryIds,\n    String? locationInfo,\n    bool? autoCaptured,");
  text = text.replaceFirst("tags: tags ?? this.tags,\n      autoCaptured: autoCaptured ?? this.autoCaptured,", "tags: tags ?? this.tags,\n      linkedRefundEntryIds: linkedRefundEntryIds ?? this.linkedRefundEntryIds,\n      locationInfo: locationInfo ?? this.locationInfo,\n      autoCaptured: autoCaptured ?? this.autoCaptured,");
  text = text.replaceFirst("'tags': tags,\n    'autoCaptured': autoCaptured,", "'tags': tags,\n    'linkedRefundEntryIds': linkedRefundEntryIds,\n    'locationInfo': locationInfo,\n    'autoCaptured': autoCaptured,");
  text = text.replaceFirst("tags: (json['tags'] as List<dynamic>? ?? const []).cast<String>(),\n    autoCaptured: json['autoCaptured'] as bool? ?? false,", "tags: (json['tags'] as List<dynamic>? ?? const []).cast<String>(),\n    linkedRefundEntryIds: (json['linkedRefundEntryIds'] as List<dynamic>? ?? const []).cast<String>(),\n    locationInfo: json['locationInfo'] as String? ?? '',\n    autoCaptured: json['autoCaptured'] as bool? ?? false,");

  // _captureToEntry
  text = text.replaceFirst('LedgerEntry _captureToEntry(AutoCaptureRecord capture, LedgerBook book) {\n    final resolvedCategoryId = inferAutoCaptureCategoryId(\n      book: book,\n      capture: capture,\n    );', 'LedgerEntry _captureToEntry(AutoCaptureRecord capture, LedgerBook book) {\n    final inferred = inferAutoCaptureCategoryId(\n      book: book,\n      capture: capture,\n    );\n    final resolvedCategoryId = inferred.\$1;\n    final customTags = inferred.\$2;');
  text = text.replaceFirst("tags: [\n        ...sourceTags,\n        scenarioLabel,\n        if (capture.confidence >= 0.85) '高置信度',\n      ]", "tags: [\n        ...sourceTags,\n        scenarioLabel,\n        ...customTags,\n        if (capture.confidence >= 0.85) '高置信度',\n      ]");

  // inferAutoCaptureCategoryId
  text = text.replaceFirst("String inferAutoCaptureCategoryId({", "(String, List<String>) inferAutoCaptureCategoryId({");
  text = text.replaceFirst("final categories = categoriesForType(capture.entryType);", "for (final rule in book.customRules) {\n    if (rule.pattern.isNotEmpty && lowercase.contains(rule.pattern.toLowerCase())) {\n      return (rule.categoryId, rule.autoTags);\n    }\n  }\n  final categories = categoriesForType(capture.entryType);");
  text = text.replaceFirst("return 'family';", "return ('family', const <String>[]);");
  text = text.replaceFirst("return keywordMatch.id;", "return (keywordMatch.id, const <String>[]);");
  text = text.replaceFirst("return 'shopping';", "return ('shopping', const <String>[]);");
  text = text.replaceFirst("return capture.defaultCategoryId;", "return (capture.defaultCategoryId, const <String>[]);");
  text = text.replaceFirst("return resolveDefaultExpenseCategoryId(book.settings);", "return (resolveDefaultExpenseCategoryId(book.settings), const <String>[]);");
  text = text.replaceFirst("return incomeKeywordMatch.id;", "return (incomeKeywordMatch.id, const <String>[]);");
  text = text.replaceFirst("return 'salary';", "return ('salary', const <String>[]);");

  // _syncCaptures link function
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

  // UI Tags
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
  text = text.replaceFirst('.toList(),\n                    ),\n                  ]', ').toList(),\n                      ],\n                    ),\n                  ]');

  // UI Settings
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

  // Insights View
  text = text.replaceFirst("                  child: _PillarTile(pillar: pillar, state: viewState),\n                ),\n            ],\n          ),\n        ),\n      ],\n    );", "                  child: _PillarTile(pillar: pillar, state: viewState),\n                ),\n              const SizedBox(height: 24),\n              HeatmapView(book: book),\n              const SizedBox(height: 24),\n              SankeyView(book: book),\n            ],\n          ),\n        ),\n      ],\n    );");

  await file.writeAsString(text);
  
  final uiFile = File('lib/src/ui_extensions.dart');
  if (await uiFile.exists()) {
    var uiText = await uiFile.readAsString();
    uiText = uiText.replaceAll('_ledgerControllerProvider', 'ledgerControllerProvider');
    uiText = uiText.replaceAll('.withOpacity(', '.withValues(alpha: ');
    uiText = uiText.replaceAll("const SankeyView({super.key, required this.book,});", "const SankeyView({super.key, required this.book});");
    // fix book parameter
    uiText = uiText.replaceAll("SettingsCustomRulesView(book: book)", "SettingsCustomRulesView(book: book!)");
    uiText = uiText.replaceAll("AssetAccountsView(book: book)", "AssetAccountsView(book: book!)");
    await uiFile.writeAsString(uiText);
  }
}
