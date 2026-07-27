// This gradle project is part of a conventional Skip app project.
pluginManagement {
    // Initialize the Skip plugin folder and perform a pre-build for non-Xcode builds
    val pluginPath = File.createTempFile("skip-plugin-path", ".tmp")

    // overriding outputs for an Android IDE can be done by un-commenting and setting the Xcode path:
    //System.setProperty("BUILT_PRODUCTS_DIR", "${System.getProperty("user.home")}/Library/Developer/Xcode/DerivedData/MySkipProject-HASH/Build/Products/Debug-iphonesimulator")

    val skipPluginResult = providers.exec {
        commandLine("/bin/sh", "-c", "skip plugin --prebuild --package-path '${settings.rootDir.parent}' --plugin-ref '${pluginPath.absolutePath}'")
        environment("PATH", "${System.getenv("PATH")}:/opt/homebrew/bin")
    }
    val skipPluginOutput = skipPluginResult.standardOutput.asText.get()
    print(skipPluginOutput)
    val skipPluginError = skipPluginResult.standardError.asText.get()
    print(skipPluginError)

    // skip 1.9.4 (SPM binary artifact) hardcodes gradle-9.0.0 in generated sub-project
    // wrappers. Patch all generated wrappers to match the ROOT wrapper's version
    // (Android/gradle/wrapper/gradle-wrapper.properties, currently 9.6.1) so the CLI,
    // fastlane and Android Studio all build the shared skipstone composite with ONE
    // Gradle version. Mixing versions across those tools corrupts the modules' shared
    // Kotlin incremental caches → "Unresolved reference 'SkipLogger'/…" (empty module
    // jars). Keep this in lockstep with the root wrapper's distributionUrl.
    providers.exec {
        commandLine("/bin/sh", "-c",
            "find '${settings.rootDir.parent}/.build/plugins/outputs' -name 'gradle-wrapper.properties'" +
            " -exec chmod u+w {} \\;" +
            " -exec sed -i '' 's|gradle-[0-9][0-9.]*-bin\\.zip|gradle-9.6.1-bin.zip|g' {} \\;")
    }.result.get()

    includeBuild(pluginPath.readText()) {
        name = "skip-plugins"
    }
}

plugins {
    id("skip-plugin") apply true
    id("org.gradle.toolchains.foojay-resolver-convention") version "1.0.0"
}
