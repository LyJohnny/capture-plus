import Foundation

/// A named save-destination folder the user can send a fresh screenshot to straight
/// from the HUD. Persisted as JSON in `AppSettings.screenshotPresets`.
struct ScreenshotPreset: Codable, Identifiable, Equatable {
    let id: UUID
    var name: String
    var path: String

    /// The preset's folder as a file URL.
    var url: URL { URL(fileURLWithPath: path) }

    init(id: UUID = UUID(), name: String, path: String) {
        self.id = id
        self.name = name
        self.path = path
    }
}
