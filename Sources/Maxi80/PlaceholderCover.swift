import Maxi80Model
import SwiftUI

/// One of the generic "Maxi'80" covers shown before any song has played, paired with the
/// dominant color sampled from that image (precomputed so the startup gradient is consistent
/// on both iOS and Android — Android has no runtime image-color APIs).
struct PlaceholderCover: Equatable, Sendable {
  /// Asset name in the module bundle.
  let imageName: String
  /// Dominant color of the image, driving the startup background gradient.
  let dominantColor: Color

  /// The bundled generic covers with their sampled dominant colors.
  static let all: [PlaceholderCover] = [
    PlaceholderCover(
      imageName: "NoCover-a", dominantColor: Color(red: 96 / 255, green: 81 / 255, blue: 72 / 255)),
    PlaceholderCover(
      imageName: "NoCover-b", dominantColor: Color(red: 69 / 255, green: 67 / 255, blue: 67 / 255)),
    PlaceholderCover(
      imageName: "NoCover-c", dominantColor: Color(red: 61 / 255, green: 42 / 255, blue: 28 / 255)),
  ]

  /// The 25th-anniversary cover (issue #71), which joins the pool only while the
  /// `anniversary_cover` flag is on so the celebration artwork can be switched off once the window
  /// closes without shipping a build. Kept out of `all` rather than filtered back out of it, so the
  /// default pool needs no knowledge of the flag.
  static let anniversary = PlaceholderCover(
    imageName: "NoCover-25ans", dominantColor: Color(red: 47 / 255, green: 31 / 255, blue: 55 / 255))

  /// An arbitrary cover for a song with no artwork of its own, so coverless slots vary across a
  /// session instead of all showing one cover picked at launch (issue #70).
  ///
  /// Derived from the song rather than rolled with `randomElement()`, because the caller is a
  /// SwiftUI computed property that re-evaluates on every render — a fresh roll there would make
  /// the cover flicker as the carousel redraws. Deriving it makes the pick stable for as long as
  /// the song is on screen, with no state to store. `SongMetadata` is `Hashable`, but `hashValue`
  /// is salted per process, so a bit-mixed FNV-1a over the text keeps this reproducible in tests.
  ///
  /// Hashes `song.identity`, not the raw fields: a DJ program arrives artist-less from the live
  /// stream and as `Maxi80` from the backend, and history dedup/`mergedWith` already treat those as
  /// one play. Hashing the raw artist would give the two representations different covers, so the
  /// cover would visibly change as the program slid from the now slot into a healed history entry.
  ///
  /// Takes the pool as a parameter instead of reading `all` directly, so the one place that knows
  /// whether the anniversary cover is in play is the coordinator that owns the feature flags — this
  /// stays a pure function of (song, pool) and remains directly testable for either pool.
  static func forSong(_ song: SongMetadata, from pool: [PlaceholderCover] = all) -> PlaceholderCover
  {
    let identity = song.identity
    var hash: UInt64 = 0xcbf2_9ce4_8422_2325
    for byte in "\(identity.artist)|\(identity.title)".utf8 {
      hash = (hash ^ UInt64(byte)) &* 0x0000_0100_0000_01b3
    }
    // Take the remainder of the *high* bits: FNV-1a's last multiply barely disturbs its low bits, so
    // `% n` on the raw hash reaches only part of an even-sized pool — with three covers that went
    // unnoticed, but a fourth (the anniversary cover) collapsed the pick to two of the four.
    return pool[Int((hash >> 32) % UInt64(pool.count))]
  }
}
