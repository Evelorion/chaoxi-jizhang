# Project-specific R8/ProGuard rules.
# Flutter and plugin keep rules are merged automatically by the toolchain.

# Vosk (JNA)
-keep class com.sun.jna.** { *; }
-keepclassmembers class * extends com.sun.jna.** { public *; }
