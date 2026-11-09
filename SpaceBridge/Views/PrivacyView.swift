import AppKit
import SwiftUI

/// Plain-language privacy promise. Every statement here must stay literally true for the code.
struct PrivacyView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                HStack(spacing: 16) {
                    Image(systemName: "lock.shield.fill")
                        .font(.system(size: 42))
                        .foregroundStyle(.green.gradient)
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Your data stays on this Mac").font(.title.weight(.bold))
                        Text("SpaceBridge works completely offline. No one — not even Genius Bridge Technologies, the developer — can see, collect or share your files or your file information.")
                            .font(.body).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                    }
                }

                LazyVGrid(columns: [GridItem(.adaptive(minimum: 230), spacing: 10)], spacing: 12) {
                    PrivacyPoint(symbol: "wifi.slash", tint: .blue, title: "Works offline",
                                 text: "Scanning, analysis, search, cleanup and CPU/RAM monitoring run entirely on your Mac and never use the internet.")
                    PrivacyPoint(symbol: "eye.slash", tint: .purple, title: "Nothing is uploaded",
                                 text: "File names, folders, paths, sizes, file contents, app lists and system information are never sent anywhere.")
                    PrivacyPoint(symbol: "person.crop.circle.badge.xmark", tint: .orange, title: "No account, no tracking",
                                 text: "No sign-up, no analytics, no ads, no crash reporters and no third-party SDKs.")
                    PrivacyPoint(symbol: "internaldrive", tint: .teal, title: "Stored only on your Mac",
                                 text: "Scan results are kept in a local cache in your Library folder. You can delete it any time in Settings.")
                    PrivacyPoint(symbol: "doc.text.magnifyingglass", tint: .green, title: "Read-only scanning",
                                 text: "SpaceBridge reads sizes and dates only. It never opens your documents (except to compare possible duplicates, on your request) and never changes files during a scan.")
                    PrivacyPoint(symbol: "trash.slash", tint: .red, title: "You stay in control",
                                 text: "Nothing is ever deleted automatically. Every removal asks you first and goes to the Trash, so you can undo it.")
                }

                SectionCard("The one exception: Pro license check", systemImage: "key") {
                    Text("If you buy SpaceBridge Pro, the app contacts the license server (Lemon Squeezy) when you activate, and about once a week to confirm your subscription. It sends **only your license key** and a random ID for this Mac — never any file or system information. The free version makes no network connections at all, and Pro keeps working offline for up to 30 days.")
                        .fixedSize(horizontal: false, vertical: true)
                }

                SectionCard("Where your data is", systemImage: "folder") {
                    LabeledContent("Scan cache", value: model.database?.url.path.abbreviatingHome ?? "Not created")
                    LabeledContent("License (Pro only)", value: "Your macOS Keychain")
                    HStack {
                        if let url = model.database?.url {
                            Button("Show Cache in Finder") { FinderActions.reveal(url.path) }
                        }
                        Button("Delete Scan Data…") { model.selection = .settings }
                    }
                }
            }
            .padding(16)
            .frame(maxWidth: 980, alignment: .leading)
        }
        .navigationTitle("Privacy")
    }
}

private struct PrivacyPoint: View {
    var symbol: String
    var tint: Color
    var title: String
    var text: String

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: symbol).font(.title2).foregroundStyle(tint).frame(width: 30)
            VStack(alignment: .leading, spacing: 4) {
                Text(title).font(.headline)
                Text(text).font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity, minHeight: 110, alignment: .topLeading)
        .background(.background.secondary, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(.separator.opacity(0.6)))
    }
}

/// First-launch welcome that states the privacy promise before the first scan.
struct WelcomeSheet: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(AppModel.self) private var model

    var body: some View {
        VStack(spacing: 18) {
            Image(nsImage: NSApp.applicationIconImage).resizable().frame(width: 88, height: 88)
            Text("Welcome to SpaceBridge").font(.largeTitle.weight(.bold))
            Text("See exactly what's using your Mac's storage, memory and CPU.").font(.title3).foregroundStyle(.secondary)
            VStack(alignment: .leading, spacing: 12) {
                Label("Works 100% offline — scanning never uses the internet.", systemImage: "wifi.slash")
                Label("Your files and file information never leave this Mac.", systemImage: "lock.shield")
                Label("The developer can't see or share your data. No account, no tracking.", systemImage: "eye.slash")
                Label("Nothing is deleted without asking you, and removals go to the Trash.", systemImage: "trash.slash")
            }
            .font(.body)
            .padding(16)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(.green.opacity(0.08), in: RoundedRectangle(cornerRadius: 12))
            HStack {
                Button("Read Privacy Details") { model.selection = .privacy; dismiss() }
                Spacer()
                Button("Get Started") { dismiss() }.buttonStyle(.borderedProminent).keyboardShortcut(.defaultAction)
            }
        }
        .padding(28)
        .frame(width: 540)
    }
}
