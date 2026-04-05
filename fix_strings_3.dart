import 'dart:io';

void main() async {
  final file = File('lib/src/ui_extensions.dart');
  var text = await file.readAsString();

  // Fix line 84: subtitle: Text("分类为: \${category.name}\
  // 自动打标: \${rule.autoTags.join(', ')}"),
  text = text.replaceAll(RegExp(r'subtitle: Text\("分类为: \$\{category\.name\}\\\r?\n自动打标: \$\{rule\.autoTags\.join\(' + r"'" + ',' + r" '" + r'\)\}"\),'), 'subtitle: Text("分类为: \${category.name}\\\\n自动打标: \${rule.autoTags.join(\\', \\')}"),');

  await file.writeAsString(text);
  print("Fixed");
}
