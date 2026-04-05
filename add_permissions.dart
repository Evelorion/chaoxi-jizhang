import 'dart:io';

void main() async {
  final file = File('android/app/src/main/AndroidManifest.xml');
  var text = await file.readAsString();

  if (!text.contains('android.permission.RECORD_AUDIO')) {
    text = text.replaceFirst(
      '<uses-permission android:name="android.permission.USE_FINGERPRINT" />',
      '<uses-permission android:name="android.permission.USE_FINGERPRINT" />\n    <uses-permission android:name="android.permission.RECORD_AUDIO" />\n    <uses-permission android:name="android.permission.INTERNET"/>\n    <uses-permission android:name="android.permission.BLUETOOTH"/>\n    <uses-permission android:name="android.permission.BLUETOOTH_ADMIN"/>\n    <uses-permission android:name="android.permission.BLUETOOTH_CONNECT"/>'
    );
    await file.writeAsString(text);
    print('Added RECORD_AUDIO permissions to AndroidManifest.xml');
  }
}
