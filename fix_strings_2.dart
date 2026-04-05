import 'dart:io';

void main() async {
  final file = File('lib/src/ui_extensions.dart');
  var text = await file.readAsString();

  // Fix line 84
  final buggyPart1 = '                    subtitle: Text("分类为: \${category.name}\\\n自动打标: \${rule.autoTags.join(\\', \\')}");';
  final fixedPart1 = '                    subtitle: Text("分类为: \${category.name}\\\\n自动打标: \${rule.autoTags.join(\\', \\')}");';
  
  // Actually regex might be easier
  text = text.replaceAll('                    subtitle: Text("分类为: \${category.name}\\\n自动打标: \${rule.autoTags.join(\\', \\')}"),', '                    subtitle: Text("分类为: \${category.name}\\\\n自动打标: \${rule.autoTags.join(\\', \\')}"),');
  
  await file.writeAsString(text);
  print("Fixed");
}
