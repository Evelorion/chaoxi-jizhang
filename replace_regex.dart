import 'dart:io';

void main() async {
  final file = File('lib/src/app.dart');
  var text = await file.readAsString();

  // LedgerBook
  text = text.replaceAll(RegExp(r'required this\.settings,\s*\}\);'), "required this.settings,\n    this.assetAccounts = const [],\n    this.customRules = const [],\n  });");
  text = text.replaceAll(RegExp(r'settings: VaultSettings\('), "assetAccounts: const [],\n      customRules: const [],\n      settings: VaultSettings(");
  text = text.replaceAll(RegExp(r'final VaultSettings settings;\s*Map<String, dynamic> toJson\(\) => \{'), "final VaultSettings settings;\n  final List<AssetAccount> assetAccounts;\n  final List<CategorizationRule> customRules;\n\n  Map<String, dynamic> toJson() => {");
  text = text.replaceAll(RegExp(r"'settings': settings.toJson\(\),\s*\};\s*\}"), "'settings': settings.toJson(),\n    'assetAccounts': assetAccounts.map((e) => e.toJson()).toList(),\n    'customRules': customRules.map((e) => e.toJson()).toList(),\n  };\n}");
  text = text.replaceAll(RegExp(r"VaultSettings\.fromJson\(json\['settings'\] as Map<String, dynamic>\),\s*\);"), "VaultSettings.fromJson(json['settings'] as Map<String, dynamic>),\n    assetAccounts: (json['assetAccounts'] as List<dynamic>? ?? []).map((e) => AssetAccount.fromJson(e as Map<String, dynamic>)).toList(),\n    customRules: (json['customRules'] as List<dynamic>? ?? []).map((e) => CategorizationRule.fromJson(e as Map<String, dynamic>)).toList(),\n  );");
  text = text.replaceAll(RegExp(r"VaultSettings(?: \?)? settings,\s*\}) \{"), "VaultSettings? settings,\n    List<AssetAccount>? assetAccounts,\n    List<CategorizationRule>? customRules,\n  }) {");
  text = text.replaceAll(RegExp(r"settings: settings \?\? this\.settings,\s*\);"), "settings: settings ?? this.settings,\n      assetAccounts: assetAccounts ?? this.assetAccounts,\n      customRules: customRules ?? this.customRules,\n    );");

  // VaultSettings
  text = text.replaceAll(RegExp(r'required this\.bankEnabled,\s*\}\);'), "required this.bankEnabled,\n    this.locationMode = LocationTrackingMode.off,\n  });");
  text = text.replaceAll(RegExp(r'final bool bankEnabled;\s*Map<String, dynamic> toJson\(\) => \{'), "final bool bankEnabled;\n  final LocationTrackingMode locationMode;\n\n  Map<String, dynamic> toJson() => {");
  text = text.replaceAll(RegExp(r"'bankEnabled': bankEnabled,\s*\};\s*\}"), "'bankEnabled': bankEnabled,\n    'locationMode': locationMode.name,\n  };\n}");
  text = text.replaceAll(RegExp(r"bankEnabled: json\['bankEnabled'\] as bool\? \?\? true,\s*\);"), "bankEnabled: json['bankEnabled'] as bool? ?? true,\n    locationMode: LocationTrackingMode.values.firstWhere((e) => e.name == (json['locationMode'] as String?), orElse: () => LocationTrackingMode.off),\n  );");
  text = text.replaceAll(RegExp(r"bool(?: \?)? bankEnabled,\s*\}) \{"), "bool? bankEnabled,\n    LocationTrackingMode? locationMode,\n  }) {");
  text = text.replaceAll(RegExp(r"bankEnabled: bankEnabled \?\? this\.bankEnabled,\s*\);"), "bankEnabled: bankEnabled ?? this.bankEnabled,\n      locationMode: locationMode ?? this.locationMode,\n    );");

  // LedgerEntry
  text = text.replaceAll(RegExp(r'this\.tags = const \[\],\s*\}\);'), "this.tags = const [],\n    this.linkedRefundEntryIds = const [],\n    this.locationInfo = '',\n  });");
  text = text.replaceAll(RegExp(r'final List<String> tags;\s*Map<String, dynamic> toJson\(\) => \{'), "final List<String> tags;\n  final List<String> linkedRefundEntryIds;\n  final String locationInfo;\n\n  Map<String, dynamic> toJson() => {");
  
  await file.writeAsString(text);
}
