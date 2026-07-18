import Testing

@testable import Maxi80Model

/// Tests for song-identity normalization — the rule that collapses the station-name artist
/// (`Maxi80`, `Maxi 80`) to empty so a backend program copy and its artist-less live copy match.
@Suite("Song Identity Tests")
struct SongIdentityTests {

  @Test("Station-name artist variants are recognized case- and whitespace-insensitively")
  func stationArtistVariantsAreRecognized() {
    for artist in ["Maxi80", "Maxi 80", "maxi80", "MAXI 80", " maxi 80 "] {
      #expect(SongMetadata(artist: artist, title: "Prog").isStationArtist)
    }
  }

  @Test("A real artist is not treated as the station name")
  func realArtistIsNotStationArtist() {
    #expect(!SongMetadata(artist: "Change", title: "A Lover's Holiday").isStationArtist)
    #expect(!SongMetadata(artist: "", title: "Prog").isStationArtist)
  }

  @Test("Identity collapses the station artist to empty, preserving the title")
  func identityCollapsesStationArtist() {
    let backend = SongMetadata(artist: "Maxi80", title: "Maxi Club avec Dj Lucky")
    let live = SongMetadata(artist: "", title: "Maxi Club avec Dj Lucky")
    #expect(backend.identity == live.identity)
    #expect(backend.identity.artist.isEmpty)
    #expect(backend.identity.title == "Maxi Club avec Dj Lucky")
  }

  @Test("Identity leaves a real artist untouched")
  func identityLeavesRealArtistUntouched() {
    let song = SongMetadata(artist: "Change", title: "A Lover's Holiday")
    #expect(song.identity == song)
  }

  @Test("Different titles never share an identity, even with the station artist")
  func differentTitlesDoNotCollapse() {
    let a = SongMetadata(artist: "Maxi80", title: "Show A")
    let b = SongMetadata(artist: "Maxi80", title: "Show B")
    #expect(a.identity != b.identity)
  }
}
