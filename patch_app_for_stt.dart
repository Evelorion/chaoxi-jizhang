import 'dart:io';

void main() async {
  final file = File('lib/src/app.dart');
  var text = await file.readAsString();

  // 1. Add stt import
  if (!text.contains('import \'package:speech_to_text/speech_to_text.dart\' as stt;')) {
    text = text.replaceFirst('import \'package:flutter/material.dart\';', 'import \'package:flutter/material.dart\';\nimport \'package:speech_to_text/speech_to_text.dart\' as stt;');
  }

  // 2. Change part
  text = text.replaceAll('part \'ui_magic_bar.dart\';', 'part \'ui_voice_fab.dart\';');

  // 3. Remove old MagicInputBar
  text = text.replaceAll(
'''        if (_selectedIndex == 0)
          MagicInputBar(book: book, controller: ref.read(ledgerControllerProvider.notifier)),''', 
''
  );

  // 4. Inject VoiceRecordingFab
  text = text.replaceFirst(
'''            SafeArea(child: _buildStateBody(context, state)),
          ],''',
'''            SafeArea(child: _buildStateBody(context, state)),
            if (_selectedIndex == 0 && state.book != null)
              VoiceRecordingFab(book: state.book!, controller: ref.read(ledgerControllerProvider.notifier)),
          ],'''
  );

  await file.writeAsString(text);
  print('Patched app.dart for VoiceRecordingFab');
}
