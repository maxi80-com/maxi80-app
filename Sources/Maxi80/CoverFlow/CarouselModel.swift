import Foundation
import Observation

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

  public init() {}

  /// True when the user has settled on a past cover that is still present. Derived (not
  /// stored) so it can never disagree with `selectedID` after a sync drops the entry.
  public var isBrowsing: Bool {
    guard let id = selectedID as? String, id != Self.nowSlotID else { return false }
    return coverIDs.contains(id)
  }

  /// The browsed history entry id, or nil when live. Derived for the same reason as
  /// `isBrowsing`: a stale focused id must be impossible by construction.
  public var focusedEntryID: String? {
    guard let id = selectedID as? String, id != Self.nowSlotID, coverIDs.contains(id) else {
      return nil
    }
    return id
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
  }

  /// Re-anchors on the now slot (back-to-live affordance and programmatic resets).
  public func returnToLive() {
    selectedID = AnyHashable(Self.nowSlotID)
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
  }
}
