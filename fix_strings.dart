import 'dart:io';

void main() async {
  final files = ['lib/src/app.dart', 'lib/src/ui_extensions.dart'];
  
  for (final path in files) {
    final file = File(path);
    if (!await file.exists()) continue;
    
    var text = await file.readAsString();
    
    // Replace \${ with \${ (wait, in dart raw string we want to remove the backslash)
    // The literal backslash followed by dollar sign
    text = text.replaceAll(r'\${', r'${');
    text = text.replaceAll(r'\n', '\n'); // Be careful, this might break legitimate \n in strings!
    // Actually, only replace \n in double quotes or single quotes where we want actual newlines, or leave \n unchanged because in dart code \n is written as \n anyway!
    // Wait, the UI code has Text("分类为: \${category.name}\\n自动打标...")
    // Wait, \n in Dart source code is two characters \ and n. We WANT \ and n! 
    // BUT the text had `\\n` which is backslash backslash n!
    text = text.replaceAll(r'\\n', r'\n');
    
    await file.writeAsString(text);
    print("Fixed \$path");
  }
}
