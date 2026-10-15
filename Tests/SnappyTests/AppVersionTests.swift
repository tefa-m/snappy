import Testing

@testable import Snappy

@Suite("AppVersion")
struct AppVersionTests {
    @Test("The build description wins over the plain bundle version")
    func prefersDescription() {
        let info: [String: Any] = [
            "CFBundleShortVersionString": "1.1.0",
            "SnappyBuildDescription": "1.1.0-7-gabc1234-dirty",
        ]
        #expect(AppVersion.menuTitle(info: info) == "Snappy 1.1.0-7-gabc1234-dirty")
    }

    @Test("Exactly on a tag the footer is just the number")
    func onTag() {
        #expect(AppVersion.menuTitle(info: ["SnappyBuildDescription": "1.1.0"]) == "Snappy 1.1.0")
    }

    @Test("Falls back to the bundle version, then to the unbundled label")
    func fallbacks() {
        #expect(AppVersion.menuTitle(info: ["CFBundleShortVersionString": "1.1.0"]) == "Snappy 1.1.0")
        #expect(AppVersion.menuTitle(info: ["SnappyBuildDescription": ""]) == "Snappy (unbundled build)")
        #expect(AppVersion.menuTitle(info: nil) == "Snappy (unbundled build)")
    }
}
