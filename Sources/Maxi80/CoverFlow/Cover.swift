/// One album-artwork tile in the cover carousel. Covers are ordered oldest → newest;
/// the rightmost tile is the persistent "now" slot.
struct Cover: Identifiable, Equatable {
  let id: String
  /// Remote artwork URL (played songs). `nil` for the startup placeholder.
  var artworkURL: String? = nil
  /// Bundled asset name (startup placeholder). `nil` for played songs.
  var assetName: String? = nil
}
