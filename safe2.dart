import 'dart:io';

void main() async {
  final file = File('lib/src/app.dart');
  var text = await file.readAsString();

  // 1. Add part
  if (!text.contains("part 'ui_extensions.dart';")) {
    text = text.replaceFirst("import 'package:uuid/uuid.dart';", "import 'package:uuid/uuid.dart';\n\npart 'ui_extensions.dart';");
  }

  // 2. LedgerBook
  const str1 = 'required this.settings,\n  });';
  const rplc1 = 'required this.settings,\n    this.assetAccounts = const [],\n    this.customRules = const [],\n  });';
  text = text.replaceFirst(str1, rplc1);

  const str2 = 'final VaultSettings settings;\n\n  Map<String, dynamic> toJson() => {';
  const rplc2 = 'final VaultSettings settings;\n  final List<AssetAccount> assetAccounts;\n  final List<CategorizationRule> customRules;\n\n  Map<String, dynamic> toJson() => {';
  text = text.replaceFirst(str2, rplc2);

  const str3 = "'settings': settings.toJson(),\n  };\n}";
  const rplc3 = "'settings': settings.toJson(),\n    'assetAccounts': assetAccounts.map((e) => e.toJson()).toList(),\n    'customRules': customRules.map((e) => e.toJson()).toList(),\n  };\n}";
  text = text.replaceFirst(str3, rplc3);

  const str4 = "VaultSettings.fromJson(json['settings'] as Map<String, dynamic>),\n  );";
  const rplc4 = "VaultSettings.fromJson(json['settings'] as Map<String, dynamic>),\n    assetAccounts: (json['assetAccounts'] as List<dynamic>? ?? []).map((e) => AssetAccount.fromJson(e as Map<String, dynamic>)).toList(),\n    customRules: (json['customRules'] as List<dynamic>? ?? []).map((e) => CategorizationRule.fromJson(e as Map<String, dynamic>)).toList(),\n  );";
  text = text.replaceFirst(str4, rplc4);

  const str5 = "VaultSettings? settings,\n  }) {";
  const rplc5 = "VaultSettings? settings,\n    List<AssetAccount>? assetAccounts,\n    List<CategorizationRule>? customRules,\n  }) {";
  text = text.replaceFirst(str5, rplc5);

  const str6 = "settings: settings ?? this.settings,\n    );";
  const rplc6 = "settings: settings ?? this.settings,\n      assetAccounts: assetAccounts ?? this.assetAccounts,\n      customRules: customRules ?? this.customRules,\n    );";
  text = text.replaceFirst(str6, rplc6);

  // 3. VaultSettings
  const vs1 = 'required this.bankEnabled,\n  });';
  const vdr1 = 'required this.bankEnabled,\n    this.locationMode = LocationTrackingMode.off,\n  });';
  text = text.replaceFirst(vs1, vdr1);

  const vs2 = 'final bool bankEnabled;\n\n  Map<String, dynamic> toJson() => {';
  const vdr2 = 'final bool bankEnabled;\n  final LocationTrackingMode locationMode;\n\n  Map<String, dynamic> toJson() => {';
  text = text.replaceFirst(vs2, vdr2);

  const vs3 = "'bankEnabled': bankEnabled,\n  };\n}";
  const vdr3 = "'bankEnabled': bankEnabled,\n    'locationMode': locationMode.name,\n  };\n}";
  text = text.replaceFirst(vs3, vdr3);

  const vs4 = "bankEnabled: json['bankEnabled'] as bool? ?? true,\n  );";
  const vdr4 = "bankEnabled: json['bankEnabled'] as bool? ?? true,\n    locationMode: LocationTrackingMode.values.firstWhere((e) => e.name == (json['locationMode'] as String?), orElse: () => LocationTrackingMode.off),\n  );";
  text = text.replaceFirst(vs4, vdr4);

  const vs5 = "bool? bankEnabled,\n  }) {";
  const vdr5 = "bool? bankEnabled,\n    LocationTrackingMode? locationMode,\n  }) {";
  text = text.replaceFirst(vs5, vdr5);

  const vs6 = "bankEnabled: bankEnabled ?? this.bankEnabled,\n    );";
  const vdr6 = "bankEnabled: bankEnabled ?? this.bankEnabled,\n      locationMode: locationMode ?? this.locationMode,\n    );";
  text = text.replaceFirst(vs6, vdr6);

  // 4. LedgerEntry
  const str7 = "required this.tags,\n    required this.autoCaptured,";
  const rplc7 = "this.tags = const [],\n    this.linkedRefundEntryIds = const [],\n    this.locationInfo = '',\n    required this.autoCaptured,";
  text = text.replaceFirst(str7, rplc7);

  const str8 = "final List<String> tags;\n  final bool autoCaptured;";
  const rplc8 = "final List<String> tags;\n  final List<String> linkedRefundEntryIds;\n  final String locationInfo;\n  final bool autoCaptured;";
  text = text.replaceFirst(str8, rplc8);

  const str9 = "'tags': tags,\n    'autoCaptured': autoCaptured,";
  const rplc9 = "'tags': tags,\n    'linkedRefundEntryIds': linkedRefundEntryIds,\n    'locationInfo': locationInfo,\n    'autoCaptured': autoCaptured,";
  text = text.replaceFirst(str9, rplc9);

  const str10 = "tags: (json['tags'] as List<dynamic>? ?? const []).cast<String>(),\n    autoCaptured: json['autoCaptured'] as bool? ?? false,";
  const rplc10 = "tags: (json['tags'] as List<dynamic>? ?? const []).cast<String>(),\n    linkedRefundEntryIds: (json['linkedRefundEntryIds'] as List<dynamic>? ?? const []).cast<String>(),\n    locationInfo: json['locationInfo'] as String? ?? '',\n    autoCaptured: json['autoCaptured'] as bool? ?? false,";
  text = text.replaceFirst(str10, rplc10);

  const str11 = "List<String>? tags,\n    bool? autoCaptured,";
  const rplc11 = "List<String>? tags,\n    List<String>? linkedRefundEntryIds,\n    String? locationInfo,\n    bool? autoCaptured,";
  text = text.replaceFirst(str11, rplc11);

  const str12 = "tags: tags ?? this.tags,\n      autoCaptured: autoCaptured ?? this.autoCaptured,";
  const rplc12 = "tags: tags ?? this.tags,\n      linkedRefundEntryIds: linkedRefundEntryIds ?? this.linkedRefundEntryIds,\n      locationInfo: locationInfo ?? this.locationInfo,\n      autoCaptured: autoCaptured ?? this.autoCaptured,";
  text = text.replaceFirst(str12, rplc12);
  
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

  await file.writeAsString(text);
}
