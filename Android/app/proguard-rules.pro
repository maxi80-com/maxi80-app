# Skip framework packages must be kept verbatim — JNI looks them up by name.
-keeppackagenames maxi80.**
-keeppackagenames skip.**
-keeppackagenames tools.skip.**
-keep class skip.** { *; }
-keep class tools.skip.** { *; }
-keep class kotlin.jvm.functions.** { *; }
-keep class com.sun.jna.** { *; }
-dontwarn java.awt.**
-keep class * implements com.sun.jna.** { *; }
-keep class * implements skip.bridge.** { *; }
-keep class **._ModuleBundleAccessor_* { *; }
-keep class maxi80.module.** { *; }
# Transpiled Maxi80Services classes are reached only via JNI-by-name from the native Swift bridge.
-keep class maxi80.services.** { *; }

# ExoPlayerImpl is the concrete class the JNI bridge receives from SharedAudioPlayer.shared().
# Media3's own consumer ProGuard rules keep the rest of the public API.
-keep class androidx.media3.exoplayer.ExoPlayerImpl { *; }
-dontwarn androidx.media3.**
