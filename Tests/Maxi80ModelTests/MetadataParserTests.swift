import Testing
@testable import Maxi80Model

@Suite("MetadataParser Edge Cases")
struct MetadataParserTests {

    // MARK: - parse() edge cases

    @Test("Empty string → empty artist and empty title")
    func emptyString() {
        let result = MetadataParser.parse("")
        #expect(result.artist == "")
        #expect(result.title == "")
    }

    @Test("Separator only ' - ' → empty artist and empty title")
    func separatorOnly() {
        let result = MetadataParser.parse(" - ")
        #expect(result.artist == "")
        #expect(result.title == "")
    }

    @Test("Multiple separators split on the LAST ' - ' (matches backend): 'A - B - C' → 'A - B', 'C'")
    func multipleSeparators() {
        let result = MetadataParser.parse("A - B - C")
        #expect(result.artist == "A - B")
        #expect(result.title == "C")
    }

    @Test("Multi-artist title stays with the artist: last ' - ' is the boundary")
    func multiArtistTitle() {
        let result = MetadataParser.parse("Michael Jackson - Diana Ross - Ease On Down The Road")
        #expect(result.artist == "Michael Jackson - Diana Ross")
        #expect(result.title == "Ease On Down The Road")
    }

    @Test("No separator treats entire string as title")
    func noSeparator() {
        let result = MetadataParser.parse("Just A Title")
        #expect(result.artist == "")
        #expect(result.title == "Just A Title")
    }

    @Test("Leading/trailing whitespace trimmed when no separator")
    func whitespaceNoSeparator() {
        let result = MetadataParser.parse("  Just A Title  ")
        #expect(result.artist == "")
        #expect(result.title == "Just A Title")
    }

    @Test("Leading/trailing whitespace trimmed around separator")
    func leadingTrailingWhitespace() {
        let result = MetadataParser.parse("  Artist  -  Title  ")
        #expect(result.artist == "Artist")
        #expect(result.title == "Title")
    }

    @Test("Unicode/emoji in metadata")
    func unicodeEmoji() {
        let result = MetadataParser.parse("🎵 Artist - 🎶 Title")
        #expect(result.artist == "🎵 Artist")
        #expect(result.title == "🎶 Title")
    }

    @Test("CJK characters in metadata")
    func cjkCharacters() {
        let result = MetadataParser.parse("坂本龍一 - 戦場のメリークリスマス")
        #expect(result.artist == "坂本龍一")
        #expect(result.title == "戦場のメリークリスマス")
    }

    @Test("Normal case: artist and title parsed correctly")
    func normalCase() {
        let result = MetadataParser.parse("Michael Jackson - Billie Jean")
        #expect(result.artist == "Michael Jackson")
        #expect(result.title == "Billie Jean")
    }

    @Test("Spaceless dash separator 'new order-blue monday' → artist 'new order', title 'blue monday'")
    func spacelessDashSeparator() {
        let result = MetadataParser.parse("new order-blue monday")
        #expect(result.artist == "new order")
        #expect(result.title == "blue monday")
    }

    // MARK: - format() edge cases

    @Test("format: empty artist returns only title")
    func formatEmptyArtist() {
        let metadata = SongMetadata(artist: "", title: "Some Title")
        let result = MetadataParser.format(metadata)
        #expect(result == "Some Title")
    }

    @Test("format: both artist and title returns 'artist - title'")
    func formatBothPresent() {
        let metadata = SongMetadata(artist: "Artist", title: "Title")
        let result = MetadataParser.format(metadata)
        #expect(result == "Artist - Title")
    }
}
