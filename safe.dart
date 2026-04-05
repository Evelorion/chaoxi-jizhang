import 'dart:io';

void main() async {
  final file = File('lib/src/app.dart');
  var text = await file.readAsString();

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

  const str7 = "this.tags = const [],\n  });";
  const rplc7 = "this.tags = const [],\n    this.linkedRefundEntryIds = const [],\n    this.locationInfo = '',\n  });";
  text = text.replaceFirst(str7, rplc7);

  const str8 = "final List<String> tags;\n\n  Map<String, dynamic> toJson() => {";
  const rplc8 = "final List<String> tags;\n  final List<String> linkedRefundEntryIds;\n  final String locationInfo;\n\n  Map<String, dynamic> toJson() => {";
  text = text.replaceFirst(str8, rplc8);

  const str9 = "'tags': tags,\n  };\n}";
  const rplc9 = "'tags': tags,\n    'linkedRefundEntryIds': linkedRefundEntryIds,\n    'locationInfo': locationInfo,\n  };\n}";
  text = text.replaceFirst(str9, rplc9);

  const str10 = "tags: (json['tags'] as List<dynamic>? ?? const []).cast<String>(),\n  );";
  const rplc10 = "tags: (json['tags'] as List<dynamic>? ?? const []).cast<String>(),\n    linkedRefundEntryIds: (json['linkedRefundEntryIds'] as List<dynamic>? ?? const []).cast<String>(),\n    locationInfo: json['locationInfo'] as String? ?? '',\n  );";
  text = text.replaceFirst(str10, rplc10);

  const str11 = "List<String>? tags,\n  }) {";
  const rplc11 = "List<String>? tags,\n    List<String>? linkedRefundEntryIds,\n    String? locationInfo,\n  }) {";
  text = text.replaceFirst(str11, rplc11);

  const str12 = "tags: tags ?? this.tags,\n    );";
  const rplc12 = "tags: tags ?? this.tags,\n      linkedRefundEntryIds: linkedRefundEntryIds ?? this.linkedRefundEntryIds,\n      locationInfo: locationInfo ?? this.locationInfo,\n    );";
  text = text.replaceFirst(str12, rplc12);

  await file.writeAsString(text);
}
