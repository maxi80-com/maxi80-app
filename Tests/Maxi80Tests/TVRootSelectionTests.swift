import SwiftUI
// Tests/Maxi80Tests/TVRootSelectionTests.swift
import Testing

@testable import Maxi80
@testable import Maxi80Services

@Suite("TV root-view selection")
struct TVRootSelectionTests {

  /// On the macOS test host isTVMode is false, so the phone UI is selected.
  @Test("selects phone UI when not in TV mode")
  @MainActor
  func selectsPhoneUIOffTV() {
    #if os(macOS)
      #expect(PlatformEnvironment.isTVMode == false)
      #expect(Maxi80RootView.shouldUseTVUI == false)
    #endif
  }

}
