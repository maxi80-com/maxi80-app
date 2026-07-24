-keeppackagenames **
-keep class skip.** { *; }
-keep class tools.skip.** { *; }
-keep class kotlin.jvm.functions.** {*;}
-keep class com.sun.jna.** { *; }
-dontwarn java.awt.**
-keep class * implements com.sun.jna.** { *; }
-keep class * implements skip.bridge.** { *; }
-keep class **._ModuleBundleAccessor_* { *; }
-keep class maxi80.module.** { *; }
# Transpiled Maxi80Services classes are reached only via JNI-by-name from the native
# Swift bridge (e.g. PlatformEnvironment), so R8 can't see the reference and would
# strip/rename them — causing ClassNotFoundException at launch in minified builds.
-keep class maxi80.services.** { *; }

# Media3 (ExoPlayer) surface used by the now-playing writeback. The phone playback path drives
# the notification metadata through the Skip JNI-by-name bridge:
# AndroidNowPlayingController.platformUpdateNowPlaying → player.getCurrentMediaItem /
# getCurrentMediaItemIndex / replaceMediaItem, rendered by DefaultMediaNotificationProvider from
# MediaItem.getMediaMetadata(). R8 can't see those by-name references in a minified release build
# and could strip/rename them, leaving the initial metadata stuck — matching issue #13. Keep the
# whole Media3 surface so the writeback pipeline survives minification.
-keep class androidx.media3.** { *; }
-dontwarn androidx.media3.**
