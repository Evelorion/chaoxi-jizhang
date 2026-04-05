import 'dart:io';

void main() async {
  final file = File('lib/src/ui_extensions.dart');
  var text = await file.readAsString();

  // Fix line 84
  final regex1 = RegExp(r'subtitle: Text\("分类为: \$\{category\.name\}\\\r?\n自动打标: \$\{rule\.autoTags\.join\(' + r"'" + r', ' + r"'" + r'\)\}"\),');
  text = text.replaceAll(regex1, r'subtitle: Text("分类为: ${category.name}\n自动打标: ${rule.autoTags.join(' + r"'" + r', ' + r"'" + r')}"),');

  // Fix line 212
  final regex2 = RegExp(r"child: Text\('快来添加你的微信、支付宝或者银行卡资产吧！\r?\n\r?\n添加期初余额后，这里的数字会随着你的流水自动增减，还原你真实的可用资金。',");
  text = text.replaceAll(regex2, r"child: Text('快来添加你的微信、支付宝或者银行卡资产吧！\n\n添加期初余额后，这里的数字会随着你的流水自动增减，还原你真实的可用资金。',");

  await file.writeAsString(text);
  print("Fixed");
}
