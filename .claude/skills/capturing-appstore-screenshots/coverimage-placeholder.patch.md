# CoverImage force-placeholder patch

Apply this to the `CoverImage` view on the release tag you're shooting. It makes
**every** cover render a bundled Maxi'80 placeholder instead of remote album art,
so no licensed artwork appears in App Store / Play screenshots.

## Find the file first — the path moves between releases

`CoverImage` is a small SwiftUI `struct` that has lived in different files:

- ~v5.0.x: `Sources/Maxi80/CoverFlowView.swift`
- later:   `Sources/Maxi80/CoverFlow/CoverImage.swift`

Locate it on YOUR tag, don't assume:

```bash
grep -rl "struct CoverImage" Sources/
```

Also confirm the placeholder helper's current shape (asset name, `PlaceholderCover.all`)
— the two edits below must match what's actually there.

## Edit 1 — force the placeholder branch

At the top of `var body`, short-circuit to the placeholder. Add the flag and the
guard (adapt the exact `body` opening to the tag):

```swift
struct CoverImage: View {
  var url: String? = nil
  var assetName: String? = nil

  // SCREENSHOT PATCH (App Store captures): force every cover to a bundled Maxi'80
  // placeholder so no licensed album art appears. NEVER ship this — discard with
  // the worktree after capturing.
  private static let forcePlaceholderForScreenshots = true

  var body: some View {
    if Self.forcePlaceholderForScreenshots {
      placeholder
    } else if let url, let imageURL = URL(string: url) {
      // ...existing remote-artwork branch unchanged...
```

## Edit 2 — vary the placeholder per cover (deterministic)

Pick one of the three bundled covers from a per-cover key so a given cover is stable
across re-renders (no flicker) but neighbors differ — important for the tvOS history
row and the peeking neighbor covers on phone/iPad/mac. Replace the placeholder's
asset name with a computed one:

```swift
  private var placeholder: some View {
    Image(placeholderAssetName, bundle: .module)
      .resizable()
      .scaledToFill()
  }

  private var placeholderAssetName: String {
    if Self.forcePlaceholderForScreenshots {
      let names = PlaceholderCover.all.map(\.imageName)   // ["NoCover-a","NoCover-b","NoCover-c"]
      let key = url ?? assetName ?? "NoCover-a"
      return names[abs(key.hashValue) % names.count]
    }
    return assetName ?? "NoCover-a"
  }
```

If `scaledToFill()` is `.aspectRatio(contentMode: contentMode)` on your tag, keep the
tag's form — only the asset name changes.

## Verify the patch took

Rebuild and screenshot: covers must show the vinyl/turntable Maxi'80 art, and the
neighbor covers must NOT all be identical. If they're identical, `PlaceholderCover.all`
has one entry or the key doesn't vary — check the placeholder list on your tag.
