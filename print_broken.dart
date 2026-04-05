import 'dart:io';

void main() {
  var lines = File('lib/src/app.dart').readAsLinesSync();
  var broken = [1145, 1154, 3249, 3266, 3348, 3896, 3921];
  for (var i in broken) {
     print('--- Line \$i ---');
     for (var j = i - 2; j <= i + 2; j++) {
       print('\${j}: \${lines[j-1]}');
     }
  }
}
