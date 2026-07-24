# google_mlkit_translation / _commons: R8 strips or rewrites parts of the
# ML Kit SDK the Flutter plugins reach via reflection, which surfaces as
# MissingPluginException(nlp#...) in release builds only. Keep them whole -
# the size cost is small next to the bundled translate JNI lib.
-keep class com.google.mlkit.** { *; }
-keep class com.google_mlkit_commons.** { *; }
-keep class com.google_mlkit_translation.** { *; }
-dontwarn com.google.mlkit.**
