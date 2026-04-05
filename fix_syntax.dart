import 'dart:io';

void main() async {
  final file = File('lib/src/app.dart');
  var text = await file.readAsString();

  // 1. Fix inferAutoCaptureCategoryId return type mismatch
  text = text.replaceFirst('return capture.defaultCategoryId;', 'return (capture.defaultCategoryId, const <String>[]);');
  text = text.replaceFirst('return _fallbackCategoryIdForType(EntryType.income);', 'return (_fallbackCategoryIdForType(EntryType.income), const <String>[]);');

  // 2. Fix app.dart:5748 layout bugs
  text = text.replaceFirst('                              )\n                            ),\n                          )\n                          ).toList(),\n                      ],', '                              )\n                            ),\n                          )\n                      ],');

  // 3. Fix $vaultUi literal injection
  text = text.replaceFirst('\\\$vaultUi', ''); // Just remove if present
  text = text.replaceFirst('\$vaultUi', ''); // Or remove without escape

  // 4. Add updateBook in LedgerController
  final updateSettingsBlock = '''
  Future<void> updateSettings(VaultSettings settings) async {
    final book = state.book;
    final passphrase = _sessionPassphrase;
    if (book == null || passphrase == null) return;

    final updated = book.copyWith(
      settings: settings,
    );
    state = state.copyWith(book: updated);
    await _repository.saveEncryptedBook(updated, passphrase);
  }''';

  final updateBookBlock = '''
  Future<void> updateSettings(VaultSettings settings) async {
    final book = state.book;
    final passphrase = _sessionPassphrase;
    if (book == null || passphrase == null) return;

    final updated = book.copyWith(
      settings: settings,
    );
    state = state.copyWith(book: updated);
    await _repository.saveEncryptedBook(updated, passphrase);
  }

  Future<void> updateBook(LedgerBook book) async {
    final passphrase = _sessionPassphrase;
    if (passphrase == null) return;
    state = state.copyWith(book: book);
    await _repository.saveEncryptedBook(book, passphrase);
  }''';

  text = text.replaceFirst(updateSettingsBlock, updateBookBlock);

  await file.writeAsString(text);

  // Fix ui_extensions.dart
  final uiFile = File('lib/src/ui_extensions.dart');
  if (await uiFile.exists()) {
    var uiText = await uiFile.readAsString();
    uiText = uiText.replaceAll('updateSettings(book.settings, book: book)', 'updateBook(book)');
    // fix positional arguments in HeatmapView and SankeyView
    uiText = uiText.replaceAll('SettingsCustomRulesView(book: book)', 'SettingsCustomRulesView(book: book)'); 
    
    // Also remove the extra ')' that might have caused issues if SankeyView was invoked weirdly
    await uiFile.writeAsString(uiText);
  }
}
