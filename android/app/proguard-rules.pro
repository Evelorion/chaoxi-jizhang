# Project-specific R8/ProGuard rules.
# Flutter and plugin keep rules are merged automatically by the toolchain.

# Vosk (JNA)
-keep class com.sun.jna.** { *; }
-keepclassmembers class * extends com.sun.jna.** { public *; }

# llama_flutter_android Pigeon/JNI callbacks in release builds.
-keep class com.write4me.llama_flutter_android.** { *; }
-keep class kotlin.jvm.functions.Function1
-keepclassmembers class * implements kotlin.jvm.functions.Function1 {
    public java.lang.Object invoke(java.lang.Object);
}
-keepclasseswithmembernames class * {
    native <methods>;
}
