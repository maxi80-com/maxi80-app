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
