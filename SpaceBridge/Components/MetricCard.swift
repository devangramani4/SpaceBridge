import SwiftUI

/// A titled container with the standard card look used across the app.
struct SectionCard<Content: View, Accessory: View>: View {
    var title: String
    var systemImage: String?
    @ViewBuilder var accessory: () -> Accessory
    @ViewBuilder var content: () -> Content

    init(_ title: String, systemImage: String? = nil, @ViewBuilder accessory: @escaping () -> Accessory, @ViewBuilder content: @escaping () -> Content) {
        self.title = title
        self.systemImage = systemImage
        self.accessory = accessory
        self.content = content
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                if let systemImage {
                    Label(title, systemImage: systemImage).font(.headline)
                } else {
                    Text(title).font(.headline)
                }
                Spacer()
                accessory()
            }
            content()
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.background.secondary, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(.separator.opacity(0.6)))
    }
}

extension SectionCard where Accessory == EmptyView {
    init(_ title: String, systemImage: String? = nil, @ViewBuilder content: @escaping () -> Content) {
        self.init(title, systemImage: systemImage, accessory: { EmptyView() }, content: content)
    }
}

/// A single headline figure.
struct MetricCard: View {
    var title: String
    var value: String
    var detail: String?
    var systemImage: String
    var tint: Color = .accentColor
    var action: (() -> Void)?

    var body: some View {
        let card = VStack(alignment: .leading, spacing: 6) {
            Label(title, systemImage: systemImage)
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .labelStyle(TintedLabelStyle(tint: tint))
            Text(value)
                .font(.system(.title2, design: .rounded).weight(.semibold))
                .monospacedDigit()
                .lineLimit(1)
                .minimumScaleFactor(0.6)
            if let detail {
                Text(detail)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
                    .truncationMode(.middle)
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity, minHeight: 92, alignment: .topLeading)
        .background(.background.secondary, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(.separator.opacity(0.6)))

        if let action {
            Button(action: action) { card.contentShape(Rectangle()) }
                .buttonStyle(.plain)
                .help("Show details")
        } else {
            card
        }
    }
}

struct TintedLabelStyle: LabelStyle {
    var tint: Color
    func makeBody(configuration: Configuration) -> some View {
        HStack(spacing: 6) {
            configuration.icon.foregroundStyle(tint)
            configuration.title
        }
    }
}

/// Horizontal capacity bar.
struct UsageBar: View {
    var fraction: Double
    var tint: Color = .accentColor
    var height: CGFloat = 10

    var body: some View {
        GeometryReader { geometry in
            ZStack(alignment: .leading) {
                Capsule().fill(.quaternary)
                Capsule().fill(tint.gradient)
                    .frame(width: max(0, min(1, fraction.isFinite ? fraction : 0)) * geometry.size.width)
            }
        }
        .frame(height: height)
        .accessibilityElement()
        .accessibilityValue(PercentFormatter.string(fraction))
    }
}

/// Text-style block meter, e.g. ██████████░░░░ for memory pressure.
struct PressureMeter: View {
    var fraction: Double
    var label: String
    var tint: Color

    var body: some View {
        HStack(spacing: 10) {
            HStack(spacing: 2) {
                ForEach(0..<20, id: \.self) { index in
                    RoundedRectangle(cornerRadius: 2)
                        .fill(Double(index) / 20 < fraction ? AnyShapeStyle(tint) : AnyShapeStyle(HierarchicalShapeStyle.quaternary))
                        .frame(width: 10, height: 16)
                }
            }
            Text(label).font(.headline).foregroundStyle(tint)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Memory pressure \(label)")
    }
}

/// Placeholder shown when a screen needs scan data first.
struct ScanRequiredView: View {
    @Environment(AppModel.self) private var model
    var title = "No scan data yet"
    var message = "Scan your Mac to see what's using space. Scanning is read-only and runs on this Mac only."

    var body: some View {
        ContentUnavailableView {
            Label(title, systemImage: "internaldrive")
        } description: {
            Text(message)
        } actions: {
            Button("Scan Mac") { model.scan.startScan() }
                .buttonStyle(.borderedProminent)
                .disabled(model.scan.isScanning || model.database == nil)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

struct PrivacyNotice: View {
    var compact = false
    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: "lock.shield.fill").foregroundStyle(.green).font(compact ? .body : .title3)
            VStack(alignment: .leading, spacing: 2) {
                Text("Works offline. Your data stays on this Mac.").font(.subheadline.weight(.semibold))
                Text(compact ? "Nothing is uploaded — not even to the developer."
                     : "SpaceBridge does not upload your files or filesystem information. No one — including the developer — can see or share your data.")
                    .font(.caption).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}

extension StorageCategory {
    var color: Color {
        switch self {
        case .other: return .gray
        case .applications: return .blue
        case .documents: return .indigo
        case .downloads: return .cyan
        case .desktop: return .teal
        case .photos: return .pink
        case .videos: return .purple
        case .music: return .red
        case .developer: return .orange
        case .xcode: return Color(red: 0.20, green: 0.55, blue: 0.95)
        case .docker: return Color(red: 0.10, green: 0.60, blue: 0.85)
        case .nodeJS: return .green
        case .npm: return Color(red: 0.80, green: 0.20, blue: 0.20)
        case .yarn: return Color(red: 0.17, green: 0.55, blue: 0.75)
        case .pnpm: return Color(red: 0.95, green: 0.65, blue: 0.10)
        case .git: return Color(red: 0.94, green: 0.32, blue: 0.20)
        case .caches: return .yellow
        case .logs: return .brown
        case .iOSBackups: return .mint
        case .android: return Color(red: 0.24, green: 0.70, blue: 0.40)
        case .virtualMachines: return Color(red: 0.45, green: 0.35, blue: 0.75)
        case .archives: return Color(red: 0.60, green: 0.50, blue: 0.35)
        case .system: return Color(white: 0.45)
        case .trash: return Color(white: 0.65)
        case .mail: return Color(red: 0.25, green: 0.45, blue: 0.85)
        case .cloudStorage: return Color(red: 0.40, green: 0.70, blue: 0.95)
        }
    }
}
