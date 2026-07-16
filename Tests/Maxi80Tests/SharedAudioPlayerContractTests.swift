import Testing
@testable import Maxi80Services

@Suite("SharedAudioPlayer generation contract")
struct SharedAudioPlayerContractTests {
    @Test("Generation is stable until reset, then increments")
    func generationLifecycle() {
        var gen = SharedPlayerGeneration()
        let a = gen.current()
        let b = gen.current()
        #expect(a == b)               // same instance era
        gen.reset()
        let c = gen.current()
        #expect(c != a)               // a new player era after release
    }
}
