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

    // skip 1.9.4 (SPM binary artifact) hardcodes gradle-9.0.0 in generated sub-project wrappers,
    // but AGP 9.2.0 requires Gradle ≥ 9.4.1. Patch all generated wrappers to match.
    providers.exec {
        commandLine("/bin/sh", "-c",
            "find '${settings.rootDir.parent}/.build/plugins/outputs' -name 'gradle-wrapper.properties'" +
            " -exec chmod u+w {} \\;" +
            " -exec sed -i '' 's|gradle-[0-9][0-9.]*-bin\\.zip|gradle-9.4.1-bin.zip|g' {} \\;")
    }.result.get()

    includeBuild(pluginPath.readText()) {
        name = "skip-plugins"
    }
}

plugins {
    id("skip-plugin") apply true
    id("org.gradle.toolchains.foojay-resolver-convention") version "1.0.0"
}
