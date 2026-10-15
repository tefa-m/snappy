import CoreGraphics
import Testing
@testable import Snappy

@Suite("PinInclusion")
struct PinInclusionTests {
    @Test func noPinsNeverNeedsAFetch() {
        #expect(!PinInclusion.needsFreshContent(pinIDs: [], listedIDs: []))
        #expect(!PinInclusion.needsFreshContent(pinIDs: [], listedIDs: [1, 2]))
    }

    @Test func listedPinsServeFromTheCache() {
        #expect(!PinInclusion.needsFreshContent(pinIDs: [5, 7], listedIDs: [1, 5, 7, 9]))
    }

    @Test func aPinNewerThanTheCacheForcesOneFreshFetch() {
        #expect(PinInclusion.needsFreshContent(pinIDs: [5, 7], listedIDs: [1, 5]))
    }

    @MainActor
    @Test func registryTracksOpenPins() {
        let id: CGWindowID = 424_242
        PinWindowRegistry.register(id)
        #expect(PinWindowRegistry.windowIDs.contains(id))
        PinWindowRegistry.unregister(id)
        #expect(!PinWindowRegistry.windowIDs.contains(id))
    }
}
