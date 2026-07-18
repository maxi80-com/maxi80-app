import Maxi80Model
// Sources/Maxi80/TV/TVHistoryRow.swift
import SwiftUI

/// A focus-navigable horizontal row of PAST covers for the TV UI, ordered oldest → newest
/// (left → right) with the newest nearest the now-playing hero above. The live "now" slot is NOT in
/// this row — it's the hero cover in `TVRadioPlayerView`; the row is history-only, built from
/// `viewModel.covers` (oldest → newest with the now slot last) minus that trailing now slot.
///
/// Both platforms open the row resting on the newest (right) cover, but by different means: tvOS uses
/// `.defaultScrollAnchor(.trailing)`; Android reverses the array and horizontally flips the row (the
/// transpiled ScrollView ignores `scrollTo` — see the carousel pin findings). See `orderedCovers`.
struct TVHistoryRow: View {
  @Bindable var viewModel: RadioPlayerViewModel
  #if os(tvOS) || os(Android)
    // The D-pad-focused cover id, so the hero updates as focus moves and the focused cell highlights.
    // `Cover.id` is `String`, so the value type is `String?` — it wraps implicitly into the view
    // model's `AnyHashable?` selection. Internal, not private: a `@FocusState` on the bridged Android
    // view must be bridgeable (tvOS accepts internal too, so both TV platforms share this).
    @FocusState var focusedID: String?
  #endif

  init(viewModel: RadioPlayerViewModel) {
    self.viewModel = viewModel
  }

  /// Past covers only — the trailing "now" slot from `viewModel.covers` is dropped (it's the hero).
  private var orderedCovers: [CoverFlowView.Cover] {
    #if os(Android)
      // Reversed (newest first) to pair with the horizontal flip in `body`: the flip maps this
      // leading (newest) edge to the visual RIGHT, so the row shows oldest-left / newest-right and
      // rests on the newest without any `scrollTo` (which the transpiled ScrollView ignores).
      Array(viewModel.covers.dropLast().reversed())
    #else
      // tvOS: natural oldest → newest; `.defaultScrollAnchor(.trailing)` opens it on the newest.
      Array(viewModel.covers.dropLast())
    #endif
  }

  var body: some View {
    #if os(tvOS)
      ScrollViewReader { proxy in
        ScrollView(.horizontal, showsIndicators: false) {
          HStack(spacing: 24) {
            ForEach(orderedCovers, id: \.id) { cover in
              coverThumbnail(cover)
                .id(cover.id)
            }
          }
          .padding(.horizontal, 60)
        }
        // Covers are oldest → newest L→R; open showing the newest (nearest "now") at the trailing
        // edge. `.defaultScrollAnchor` sets the initial offset without an `onAppear`/`scrollTo` race.
        .defaultScrollAnchor(.trailing)
        // `.focusSection()` makes the whole row one focus target: a D-pad *up* from ANY cover
        // routes to the control section above (and *down* returns here), instead of tvOS's
        // geometric default where only the covers directly beneath the play button can move up.
        .focusSection()
        // Focusing a history cover selects it (updating the hero + labels). Leaving the row
        // (moving up to the controls) must NOT reset to live — otherwise `isBrowsingHistory`
        // flips false and the "Back to live" pill disappears before it can be reached. The
        // selection persists until the user explicitly taps "Back to live".
        .onChange(of: focusedID) { _, newValue in
          if let newValue {
            viewModel.selectedCoverID = newValue
          }
        }
        // Re-pin the row to the newest (rightmost) cover, matching the phone's Cover Flow: key
        // on `coverPinToken` (which folds in `returnToLiveNonce`, so tapping "Back to live"
        // re-fires this) and, while not browsing, jump to the newest cover. Non-animated after a
        // short settle — an animated scrollTo sweeps the row through intermediate cells and
        // cancels their AsyncImage loads, leaving older covers stuck on placeholders.
        .task(id: viewModel.coverPinToken) {
          guard !viewModel.isBrowsingHistory, let target = orderedCovers.last?.id else { return }
          try? await Task.sleep(nanoseconds: 60_000_000)
          proxy.scrollTo(target, anchor: .trailing)
        }
      }
    #elseif os(Android)
      // Android: `orderedCovers` is reversed (newest first). Flipping the whole ScrollView
      // horizontally (`scaleEffect(x: -1)`) makes Compose's leading-edge rest position land on the
      // visual RIGHT, so the row opens on the newest cover with no `scrollTo` (which the transpiled
      // ScrollView ignores). Each cell is counter-flipped in `coverThumbnail` so artwork is not
      // mirrored. Result: oldest at the left, newest at the right, opened on the right.
      ScrollView(.horizontal, showsIndicators: false) {
        HStack(spacing: 24) {
          ForEach(orderedCovers, id: \.id) { cover in
            coverThumbnail(cover)
              .id(cover.id)
          }
        }
        .padding(.horizontal, 60)
      }
      .scaleEffect(x: -1, y: 1, anchor: .center)
      // "Back to live" (and a new song) bump `coverPinToken` — but NOT plain browsing. Keying the
      // ScrollView's identity on it remounts the row on those events, so it rebuilds fresh and
      // re-rests at its leading edge (= newest = visual right via the flip). This is deterministic
      // where `scrollTo` isn't: the transpiled Android ScrollView ignores programmatic scrolls.
      .id(viewModel.coverPinToken)
      // As D-pad focus moves across covers, select the focused one so the hero + labels track it
      // (mirrors tvOS). Moving focus off the row leaves the last selection in place until the user
      // taps "Back to live".
      .onChange(of: focusedID) { _, newValue in
        if let newValue {
          viewModel.selectedCoverID = newValue
        }
      }
    #else
      ScrollView(.horizontal, showsIndicators: false) {
        HStack(spacing: 24) {
          ForEach(orderedCovers, id: \.id) { cover in
            coverThumbnail(cover)
              .id(cover.id)
          }
        }
        .padding(.horizontal, 60)
      }
    #endif
  }

  @ViewBuilder
  private func coverThumbnail(_ cover: CoverFlowView.Cover) -> some View {
    #if os(Android)
      // On Android the Button label doesn't inherit the image's `.frame`, so the Coil-backed cover
      // stretches to its intrinsic (non-square) ratio. Constrain + clip the image, then also pin the
      // Button itself to the square so the label can't expand it. ~20% smaller than tvOS to fit.
      let image = CoverImage(url: cover.artworkURL, assetName: cover.assetName)
        .frame(width: 144, height: 144)
        .clipShape(RoundedRectangle(cornerRadius: 12))

      // Counter-flip: the row's ScrollView is mirrored (`scaleEffect(x: -1)`) to rest on the newest
      // cover, so each cell flips back to render artwork the right way round. The focused cover gets
      // a scale-up + orange border so the current selection is clearly visible on the 10-foot UI.
      let isFocused = focusedID == cover.id
      Button {
        viewModel.selectedCoverID = cover.id
      } label: {
        image.overlay(
          RoundedRectangle(cornerRadius: 12)
            .stroke(Color.orange, lineWidth: isFocused ? 4 : 0)
        )
      }
      .buttonStyle(.plain)
      .frame(width: 144, height: 144)
      .scaleEffect(x: isFocused ? -1.12 : -1, y: isFocused ? 1.12 : 1, anchor: .center)
      .focused($focusedID, equals: cover.id)
      .animation(.easeInOut(duration: 0.15), value: isFocused)
    #elseif os(tvOS)
      let image = CoverImage(url: cover.artworkURL, assetName: cover.assetName)
        .frame(width: 180, height: 180)
        .clipShape(RoundedRectangle(cornerRadius: 12))

      Button {
        viewModel.selectedCoverID = cover.id
      } label: {
        image
      }
      .buttonStyle(.card)
      .focused($focusedID, equals: cover.id)
    #else
      let image = CoverImage(url: cover.artworkURL, assetName: cover.assetName)
        .frame(width: 180, height: 180)
        .clipShape(RoundedRectangle(cornerRadius: 12))

      Button {
        viewModel.selectedCoverID = cover.id
      } label: {
        image
      }
      .buttonStyle(.plain)
    #endif
  }
}
