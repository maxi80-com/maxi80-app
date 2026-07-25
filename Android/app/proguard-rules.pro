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
# and could strip/rename them, leaving the initial metadata stuck — matching issue #13.
#
# Deliberately broad (whole `androidx.media3.**`, not just `.common.**`) rather than relying on
# Media3's own consumer ProGuard rules: the by-name bridge reflects on the CONCRETE runtime type
# returned by SharedAudioPlayer.shared() — an ExoPlayer whose implementation lives in
# `androidx.media3.exoplayer` (ExoPlayerImpl), not `androidx.media3.common`. Scoping the keep to
# `.common.**` would leave the actually-reflected methods (getCurrentMediaItem / replaceMediaItem /
# getCurrentMediaItemIndex) on the impl class renamable, reintroducing the R8-strips-JNI-bridged-
# class crash. The keep is chosen over Media3's consumer rules for that reason.
-keep class androidx.media3.** { *; }
-dontwarn androidx.media3.**
