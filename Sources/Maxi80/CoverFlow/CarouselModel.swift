import Foundation
import Observation
// SkipFuse registers the @Observable with the bridge so mutations invalidate the Android
// Compose UI — the view model's computed selection properties read through this model.
import SkipFuse

/// Canonical selection state for the Cover Flow carousel.
///
/// This type exists to invert the usual scroll-view relationship: renderers FOLLOW
/// `selectedID` (the selected cover is centered by construction) and report back only
/// *settled user gestures* via `userSettledOn(_:)`. Because no transient layout geometry
/// (content offsets, scroll phases, in-flight animations) ever feeds into the selection,
/// the drift/recoil bug class that killed the ScrollView-based renderers is structurally
/// impossible — no reconciliation guards, pin tokens, or backstop timers are needed.
///
/// The model is renderer-agnostic so a future Android Compose renderer can share it.
@MainActor
@Observable
public final class CarouselModel {
  /// Sentinel id for the persistent rightmost "now playing" slot. It is not a history
  /// entry, so it is always a valid settle target even before any history has loaded.
  public static let nowSlotID = "__now__"

  /// Ordered cover ids, oldest → newest, with the now slot always last.
  public private(set) var coverIDs: [String] = [CarouselModel.nowSlotID]

  /// The id the renderer must keep centered. `AnyHashable` because renderers hand back
  /// whatever id type their cell identity uses; the model only trusts `String` ids.
  public private(set) var selectedID: AnyHashable = AnyHashable(CarouselModel.nowSlotID)

  /// The id the DISPLAY surfaces follow (song label, background wash, back-to-live button).
  /// On Apple platforms it mirrors `selectedID` synchronously. On Android it lags by
  /// `displaySyncDelay`: flipping it recomposes most of the screen, and doing that the instant
  /// a drag releases landed a 200ms+ recomposition in the middle of the settle glide on
  /// low-end phones (A07) — the measured "mid-animation freeze". Deferring it lets the cover
  /// glide and pin first; the labels and background then update in a settled frame. Rapid
  /// consecutive settles coalesce: only the last one syncs.
  public private(set) var displaySelectedID: AnyHashable = AnyHashable(CarouselModel.nowSlotID)

  /// How long after a selection change the display surfaces follow, on Android. Slightly past
  /// the settle spring's visual travel (response 0.4) so the recomposition lands after the
  /// glide, not during it.
  private static let displaySyncDelay: Duration = .milliseconds(450)

  /// In-flight deferred display sync; each selection change supersedes the previous one.
  @ObservationIgnored private var displaySyncTask: Task<Void, Never>?

  public init() {}

  /// True when the user has settled on a past cover that is still present. Derived (not
  /// stored) so it can never disagree with the selection after a sync drops the entry.
  /// Reads through `displaySelectedID`: every consumer is a display surface, and following
  /// the deferred id keeps ALL of them (label, wash, button) flipping in the same frame.
  public var isBrowsing: Bool {
    guard let id = displaySelectedID as? String, id != Self.nowSlotID else { return false }
    return coverIDs.contains(id)
  }

  /// The browsed history entry id, or nil when live. Derived for the same reason as
  /// `isBrowsing`: a stale focused id must be impossible by construction. Display-deferred
  /// like `isBrowsing`.
  public var focusedEntryID: String? {
    guard let id = displaySelectedID as? String, id != Self.nowSlotID, coverIDs.contains(id)
    else { return nil }
    return id
  }

  /// Routes a selection change to the display id — synchronously on Apple platforms,
  /// deferred by `displaySyncDelay` on Android (see `displaySelectedID`). A newer change
  /// cancels and supersedes any pending sync so only the final selection lands.
  private func scheduleDisplaySync() {
    displaySyncTask?.cancel()
    #if os(Android)
      let target = selectedID
      displaySyncTask = Task { [weak self] in
        try? await Task.sleep(for: Self.displaySyncDelay)
        guard !Task.isCancelled else { return }
        self?.displaySelectedID = target
      }
    #else
      displaySelectedID = selectedID
    #endif
  }

  /// Records where a *user gesture* settled. The now slot is always accepted (it exists
  /// before any sync); any other id must currently be in `coverIDs` — a stale id from a
  /// cover that rolled off mid-drag is silently ignored so the renderer's spring simply
  /// returns to the current anchor. Non-`String` ids are ignored: they cannot have come
  /// from this model's cover list.
  public func userSettledOn(_ id: AnyHashable) {
    guard let settled = id as? String else { return }
    guard settled == Self.nowSlotID || coverIDs.contains(settled) else { return }
    selectedID = AnyHashable(settled)
    scheduleDisplaySync()
  }

  /// Re-anchors on the now slot (back-to-live affordance and programmatic resets). The
  /// display id follows immediately even on Android: this is a button tap, not a drag
  /// release — there is no in-flight glide to protect, and the user expects instant feedback.
  public func returnToLive() {
    displaySyncTask?.cancel()
    selectedID = AnyHashable(Self.nowSlotID)
    displaySelectedID = selectedID
  }

  /// Replaces the cover list. Called from a computed property on every render pass, so
  /// the unchanged case MUST be a no-op that touches no observable state — otherwise
  /// every render would invalidate observers and re-render forever.
  ///
  /// If the current selection is a past cover that vanished from the new list, the
  /// selection falls back to the now slot; a browsed cover that survives the sync keeps
  /// the selection (append-while-browsing must not yank the user back to live).
  public func syncCoverIDs(_ ids: [String]) {
    guard ids != coverIDs else { return }
    coverIDs = ids
    if let selected = selectedID as? String, selected != Self.nowSlotID, !ids.contains(selected) {
      selectedID = AnyHashable(Self.nowSlotID)
    }
    // The display id may reference an entry the sync just dropped; snap it to the (possibly
    // fallen-back) selection immediately — a stale display id must not outlive the sync, and
    // there is no glide in flight here. A pending drag-release sync is superseded.
    if displaySelectedID != selectedID,
      let display = displaySelectedID as? String,
      display != Self.nowSlotID, !ids.contains(display)
    {
      displaySyncTask?.cancel()
      displaySelectedID = selectedID
    }
  }
}
