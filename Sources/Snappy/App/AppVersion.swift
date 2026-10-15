import Foundation

/// PURE formatting of the build's version for display. The values are written
/// into Info.plist by `scripts/bundle.sh` from the git tag — never hardcoded
/// (docs/features/versioning.md).
enum AppVersion {
    /// `SnappyBuildDescription` — "1.1.0" exactly on a tag, else
    /// "1.1.0-7-gabc1234" (+ "-dirty"). Falls back to the plain bundle version.
    static func description(info: [String: Any]?) -> String? {
        for key in ["SnappyBuildDescription", "CFBundleShortVersionString"] {
            if let value = info?[key] as? String, !value.isEmpty { return value }
        }
        return nil
    }

    /// The disabled footer item in the menu bar menu.
    static func menuTitle(info: [String: Any]?) -> String {
        guard let description = description(info: info) else { return "Snappy (unbundled build)" }
        return "Snappy \(description)"
    }

    static var menuTitle: String { menuTitle(info: Bundle.main.infoDictionary) }
}
