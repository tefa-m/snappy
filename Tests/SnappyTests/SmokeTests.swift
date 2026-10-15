import Testing
@testable import Snappy

@Suite struct SmokeTests {
    /// M0 placeholder: proves the test target builds, links against the app
    /// module, and `swift test` runs green. Real logic tests start in M1.
    @Test func testTargetLinksAgainstAppModule() {
        #expect(Bool(true))
    }
}
