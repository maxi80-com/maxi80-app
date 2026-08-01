import Testing

@testable import Maxi80

/// Behavioral contract for the canonical carousel selection state (design spec §2/§6).
/// These cases pin the invariants the renderer relies on: the now slot always exists,
/// browsing state derives from (selectedID, coverIDs) so it can never go stale, and
/// syncCoverIDs is safe to call on every render.
@Suite("CarouselModel")
@MainActor
struct CarouselModelTests {

  @Test("starts at now slot, not browsing, focusedEntryID nil")
  func startsAtNowSlot() {
    let model = CarouselModel()
    #expect(model.coverIDs == [CarouselModel.nowSlotID])
    #expect(model.selectedID == AnyHashable(CarouselModel.nowSlotID))
    #expect(!model.isBrowsing)
    #expect(model.focusedEntryID == nil)
  }

  @Test("settling on a synced past cover enters browsing with focusedEntryID set")
  func settlingOnPastCoverEntersBrowsing() {
    let model = CarouselModel()
    model.syncCoverIDs(["a", "b", CarouselModel.nowSlotID])
    model.userSettledOn(AnyHashable("b"))
    #expect(model.selectedID == AnyHashable("b"))
    #expect(model.isBrowsing)
    #expect(model.focusedEntryID == "b")
  }

  @Test("returnToLive clears browsing")
  func returnToLiveClearsBrowsing() {
    let model = CarouselModel()
    model.syncCoverIDs(["a", CarouselModel.nowSlotID])
    model.userSettledOn(AnyHashable("a"))
    #expect(model.isBrowsing)
    model.returnToLive()
    #expect(model.selectedID == AnyHashable(CarouselModel.nowSlotID))
    #expect(!model.isBrowsing)
    #expect(model.focusedEntryID == nil)
  }

  @Test("sync that still contains the browsed id preserves selection (append while browsing)")
  func appendWhileBrowsingPreservesSelection() {
    let model = CarouselModel()
    model.syncCoverIDs(["a", "b", CarouselModel.nowSlotID])
    model.userSettledOn(AnyHashable("a"))
    // A new song lands while the user browses: entry appended before the now slot.
    model.syncCoverIDs(["a", "b", "c", CarouselModel.nowSlotID])
    #expect(model.selectedID == AnyHashable("a"))
    #expect(model.isBrowsing)
    #expect(model.focusedEntryID == "a")
  }

  @Test("sync that drops the browsed id falls back to the now slot")
  func droppedBrowsedIDFallsBackToNowSlot() {
    let model = CarouselModel()
    model.syncCoverIDs(["a", "b", CarouselModel.nowSlotID])
    model.userSettledOn(AnyHashable("a"))
    // History cap rolls the oldest entry off while it is being browsed.
    model.syncCoverIDs(["b", "c", CarouselModel.nowSlotID])
    #expect(model.selectedID == AnyHashable(CarouselModel.nowSlotID))
    #expect(!model.isBrowsing)
    #expect(model.focusedEntryID == nil)
  }

  @Test("userSettledOn an id not in the list is ignored")
  func staleSettleIsIgnored() {
    let model = CarouselModel()
    model.syncCoverIDs(["a", CarouselModel.nowSlotID])
    model.userSettledOn(AnyHashable("ghost"))
    #expect(model.selectedID == AnyHashable(CarouselModel.nowSlotID))
    #expect(!model.isBrowsing)
  }

  @Test("userSettledOn the now slot is always accepted, even before any sync")
  func nowSlotSettleAlwaysAccepted() {
    let model = CarouselModel()
    model.userSettledOn(AnyHashable(CarouselModel.nowSlotID))
    #expect(model.selectedID == AnyHashable(CarouselModel.nowSlotID))
    #expect(!model.isBrowsing)
  }

  @Test("sync with an identical list is a no-op that keeps a browsed selection")
  func identicalSyncIsNoOp() {
    let model = CarouselModel()
    let ids = ["a", "b", CarouselModel.nowSlotID]
    model.syncCoverIDs(ids)
    model.userSettledOn(AnyHashable("b"))
    // Called from a computed property on every render — must not disturb anything.
    model.syncCoverIDs(ids)
    #expect(model.coverIDs == ids)
    #expect(model.selectedID == AnyHashable("b"))
    #expect(model.isBrowsing)
    #expect(model.focusedEntryID == "b")
  }
}
