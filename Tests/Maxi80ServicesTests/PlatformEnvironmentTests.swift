import Testing
@testable import Maxi80Services

@Suite("PlatformEnvironment")
struct PlatformEnvironmentTests {

    /// On non-TV Apple platforms (the swift-test host is macOS), isTVMode is false.
    @Test("isTVMode is false on the macOS test host")
    func isTVModeFalseOnMac() {
        #if os(macOS)
        #expect(PlatformEnvironment.isTVMode == false)
        #endif
    }

    /// The property is callable on every platform without throwing or trapping.
    @Test("isTVMode is callable")
    func isTVModeCallable() {
        _ = PlatformEnvironment.isTVMode
    }
}
