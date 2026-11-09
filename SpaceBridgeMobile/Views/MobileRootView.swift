import StoreKit
import SwiftUI

/// Tabs on iPhone, sidebar on iPad (and iPhone landscape on Max models).
struct MobileRootView: View {
    @Environment(MobileModel.self) private var model
    @Environment(\.horizontalSizeClass) private var sizeClass
    @State private var tab: MobileSection = .overview

    var body: some View {
        @Bindable var model = model
        Group {
            if sizeClass == .regular {
                NavigationSplitView {
                    List(MobileSection.allCases, selection: $model.selection) { section in
                        Label(section.title, systemImage: section.symbolName).tag(section)
                    }
                    .navigationTitle("SpaceBridge")
                    .safeAreaInset(edge: .bottom) { ProStatusRow().padding() }
                } detail: {
                    NavigationStack { screen(model.selection ?? .overview) }
                }
            } else {
                TabView(selection: $tab) {
                    ForEach([MobileSection.overview, .photos, .files, .device]) { section in
                        NavigationStack { screen(section) }
                            .tabItem { Label(section.title, systemImage: section.symbolName) }
                            .tag(section)
                    }
                    NavigationStack { MoreView() }
                        .tabItem { Label("More", systemImage: "ellipsis.circle") }
                        .tag(MobileSection.settings)
                }
            }
        }
        .sheet(isPresented: $model.showPaywall) { MobilePaywallView() }
        .alert("Something went wrong", isPresented: Binding(get: { model.errorMessage != nil }, set: { if !$0 { model.errorMessage = nil } })) {
            Button("OK", role: .cancel) {}
        } message: { Text(model.errorMessage ?? "") }
    }

    @ViewBuilder
    private func screen(_ section: MobileSection) -> some View {
        switch section {
        case .overview: MobileOverviewView()
        case .photos: PhotosHubView()
        case .files: FilesView()
        case .device: DeviceView()
        case .tips: TipsView()
        case .privacy: MobilePrivacyView()
        case .settings: MobileSettingsView()
        }
    }
}

private struct MoreView: View {
    var body: some View {
        List {
            NavigationLink { TipsView() } label: { Label("Storage Tips", systemImage: "lightbulb") }
            NavigationLink { MobilePrivacyView() } label: { Label("Privacy", systemImage: "hand.raised") }
            NavigationLink { MobileSettingsView() } label: { Label("Settings & Pro", systemImage: "gearshape") }
        }
        .navigationTitle("More")
    }
}

struct ProStatusRow: View {
    @Environment(MobileModel.self) private var model

    var body: some View {
        if model.pro.isPro {
            Label("SpaceBridge Pro", systemImage: "checkmark.seal.fill").font(.footnote.weight(.semibold)).foregroundStyle(.purple)
        } else {
            Button { model.showPaywall = true } label: {
                Label("Upgrade to Pro", systemImage: "sparkles")
                    .font(.footnote.weight(.bold))
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 10)
                    .foregroundStyle(.white)
                    .background(LinearGradient(colors: [.purple, .blue], startPoint: .leading, endPoint: .trailing), in: RoundedRectangle(cornerRadius: 10))
            }
            .buttonStyle(.plain)
        }
    }
}

struct MobileProBadge: View {
    var body: some View {
        Text("PRO")
            .font(.system(size: 10, weight: .heavy, design: .rounded))
            .foregroundStyle(.white)
            .padding(.horizontal, 6).padding(.vertical, 2)
            .background(LinearGradient(colors: [.purple, .blue], startPoint: .leading, endPoint: .trailing), in: Capsule())
    }
}

/// Apple's native subscription screen (handles prices in local currency, trials, restore and legal text).
struct MobilePaywallView: View {
    @Environment(MobileModel.self) private var model
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        SubscriptionStoreView(productIDs: MobileProStore.productIDs) {
            VStack(spacing: 14) {
                Image(systemName: "sparkles").font(.system(size: 40)).foregroundStyle(.purple)
                Text("SpaceBridge Pro").font(.largeTitle.weight(.bold))
                Text("Free up space on your iPhone — privately, on-device.").foregroundStyle(.secondary).multilineTextAlignment(.center)
                VStack(alignment: .leading, spacing: 10) {
                    ForEach(MobileProFeature.allCases) { feature in
                        Label {
                            VStack(alignment: .leading, spacing: 1) {
                                Text(feature.title).fontWeight(.semibold)
                                Text(feature.detail).font(.caption).foregroundStyle(.secondary)
                            }
                        } icon: {
                            Image(systemName: feature.symbolName).foregroundStyle(.purple)
                        }
                    }
                }
                .padding(.top, 6)
                Label("Works offline. Your photos and files never leave this device.", systemImage: "lock.shield.fill")
                    .font(.footnote).foregroundStyle(.green)
            }
            .padding()
        }
        .storeButton(.visible, for: .restorePurchases)
        .subscriptionStoreControlStyle(.picker)
        .onInAppPurchaseCompletion { _, _ in
            await model.pro.refresh()
            if model.pro.isPro { dismiss() }
        }
    }
}
