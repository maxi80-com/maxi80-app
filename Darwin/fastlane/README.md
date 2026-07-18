fastlane documentation
----

# Installation

Make sure you have the latest version of the Xcode command line tools installed:

```sh
xcode-select --install
```

For _fastlane_ installation instructions, see [Installing _fastlane_](https://docs.fastlane.tools/#installing-fastlane)

# Available Actions

### assemble

```sh
[bundle exec] fastlane assemble
```



### metadata

```sh
[bundle exec] fastlane metadata
```

iOS: push store listing (text + iPhone screenshots) as a DRAFT — no binary, no review

### upload

```sh
[bundle exec] fastlane upload
```

Upload the EXISTING built binary to TestFlight (no rebuild). options[:platform]=ios|tvos|macos

### release

```sh
[bundle exec] fastlane release
```

iOS: full App Store submission — submits the current build FOR REVIEW (promote step)

### metadata_tvos

```sh
[bundle exec] fastlane metadata_tvos
```

tvOS: push store listing (text + Apple TV screenshots) as a DRAFT — no binary, no review

### metadata_mac

```sh
[bundle exec] fastlane metadata_mac
```

macOS: push store listing (text + Mac screenshots) as a DRAFT — no binary, no review

----

This README.md is auto-generated and will be re-generated every time [_fastlane_](https://fastlane.tools) is run.

More information about _fastlane_ can be found on [fastlane.tools](https://fastlane.tools).

The documentation of _fastlane_ can be found on [docs.fastlane.tools](https://docs.fastlane.tools).
