fastlane documentation
----

# Installation

Make sure you have the latest version of the Xcode command line tools installed:

```sh
xcode-select --install
```

For _fastlane_ installation instructions, see [Installing _fastlane_](https://docs.fastlane.tools/#installing-fastlane)

# Available Actions

### build

```sh
[bundle exec] fastlane build
```

Build Skip Android App

### test

```sh
[bundle exec] fastlane test
```

Test Skip Android App

### assemble

```sh
[bundle exec] fastlane assemble
```

Assemble Skip Android App

### upload

```sh
[bundle exec] fastlane upload
```

Upload the EXISTING signed AAB to Google Play (no rebuild)

### release

```sh
[bundle exec] fastlane release
```

Build + upload to Google Play (rebuilds, then uploads) — standalone convenience

----

This README.md is auto-generated and will be re-generated every time [_fastlane_](https://fastlane.tools) is run.

More information about _fastlane_ can be found on [fastlane.tools](https://fastlane.tools).

The documentation of _fastlane_ can be found on [docs.fastlane.tools](https://docs.fastlane.tools).
