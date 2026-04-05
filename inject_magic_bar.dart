import 'dart:io';

void main() async {
  final file = File('lib/src/app.dart');
  var text = await file.readAsString();

  // 1. Inject parts
  final partTarget = 'part \'ui_predict_cards.dart\';';
  text = text.replaceFirst(partTarget, 'part \'ui_predict_cards.dart\';\npart \'nlp_engine.dart\';\npart \'ui_magic_bar.dart\';');

  // 2. Inject MagicInputBar into LedgerRootPage
  final target = '''        Expanded(
          child: IndexedStack(
            index: _selectedIndex.clamp(0, screens.length - 1),
            children: [
              for (var i = 0; i < screens.length; i++)
                TickerMode(
                  enabled: _selectedIndex == i,
                  child: KeyedSubtree(key: ValueKey(i), child: screens[i]),
                ),
            ],
          ),
        ),
      ],''';

  final replaceWith = '''        Expanded(
          child: IndexedStack(
            index: _selectedIndex.clamp(0, screens.length - 1),
            children: [
              for (var i = 0; i < screens.length; i++)
                TickerMode(
                  enabled: _selectedIndex == i,
                  child: KeyedSubtree(key: ValueKey(i), child: screens[i]),
                ),
            ],
          ),
        ),
        if (_selectedIndex == 0)
          MagicInputBar(book: book, controller: ref.read(ledgerControllerProvider.notifier)),
      ],''';

  text = text.replaceFirst(target, replaceWith);

  await file.writeAsString(text);
  print('Injected MagicInputBar into LedgerRootPage');
}
