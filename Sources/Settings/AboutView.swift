import SwiftUI
import AppKit

/// A compact "About Capture +" block: app icon, name, version/build, tagline, and a
/// short summary of what the app does. Designed to sit as the first `Section`
/// inside the grouped settings `Form`, so it returns a `Section` from its body.
struct AboutView: View {

    /// "CFBundleShortVersionString" — the marketing version (e.g. "1.2").
    private var shortVersion: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "—"
    }

    /// "CFBundleVersion" — the build number.
    private var build: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "—"
    }

    private let features = [
        "Screenshot snippets",
        "Screen recording with system audio",
        "Clipboard history",
    ]

    var body: some View {
        Section {
            HStack(alignment: .top, spacing: 14) {
                icon
                VStack(alignment: .leading, spacing: 3) {
                    Text("Capture +")
                        .font(.title2.weight(.semibold))
                    Text("Version \(shortVersion) (\(build))")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                    Text("Snips, recordings, and clipboard history from the menu bar.")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 0)
            }
            .padding(.vertical, 4)

            VStack(alignment: .leading, spacing: 4) {
                ForEach(features, id: \.self) { feature in
                    Label(feature, systemImage: "checkmark.circle.fill")
                        .font(.callout)
                        .foregroundStyle(.primary)
                        .labelStyle(.titleAndIcon)
                }
            }

            Text("Personal utility — not for distribution.")
                .font(.caption)
                .foregroundStyle(.tertiary)
        }
    }

    @ViewBuilder
    private var icon: some View {
        if let appIcon = NSApp.applicationIconImage {
            Image(nsImage: appIcon)
                .resizable()
                .frame(width: 56, height: 56)
                .accessibilityHidden(true)
        } else {
            Image(systemName: "camera.viewfinder")
                .font(.system(size: 44))
                .foregroundStyle(.tint)
                .frame(width: 56, height: 56)
                .accessibilityHidden(true)
        }
    }
}
