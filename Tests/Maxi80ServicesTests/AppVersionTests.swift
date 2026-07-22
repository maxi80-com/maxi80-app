import Testing

@testable import Maxi80Services

@Suite("AppVersion")
struct AppVersionTests {

  /// The property is callable on every platform without throwing or trapping.
  @Test("displayString is callable")
  func displayStringCallable() {
    _ = AppVersion.displayString
  }

  /// The stamp always carries the `v…(…)` shape regardless of which platform's values fill it in,
  /// even when the underlying Info.plist/PackageInfo values are empty on a test host.
  @Test("displayString has the v<marketing> (<build>) shape")
  func displayStringFormat() {
    let stamp = AppVersion.displayString
    #expect(stamp.hasPrefix("v"))
    #expect(stamp.contains("("))
    #expect(stamp.hasSuffix(")"))
  }
}
