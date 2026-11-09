import SwiftUI

/// Small "PRO" capsule shown next to paid features.
struct ProBadge: View {
    var body: some View {
        Text("PRO")
            .font(.system(size: 9, weight: .heavy, design: .rounded))
            .foregroundStyle(.white)
            .padding(.horizontal, 5)
            .padding(.vertical, 2)
            .background(LinearGradient(colors: [.purple, .blue], startPoint: .leading, endPoint: .trailing), in: Capsule())
            .accessibilityLabel("Pro feature")
    }
}

/// Upgrade sheet ("paywall").
struct ProUpgradeView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    var highlighted: ProFeature?
    @State private var licenseKey = ""
    @State private var showKeyField = false

    private let columns = [GridItem(.flexible(), spacing: 12), GridItem(.flexible(), spacing: 12)]

    var body: some View {
        let pro = model.pro
        VStack(spacing: 0) {
            ZStack {
                LinearGradient(colors: [Color(red: 0.25, green: 0.20, blue: 0.75), Color(red: 0.10, green: 0.45, blue: 0.95)],
                               startPoint: .topLeading, endPoint: .bottomTrailing)
                VStack(spacing: 6) {
                    Image(systemName: "sparkles").font(.system(size: 30, weight: .semibold)).foregroundStyle(.white)
                    Text("SpaceBridge Pro").font(.system(size: 26, weight: .bold, design: .rounded)).foregroundStyle(.white)
                    Text(highlighted.map { "\($0.title) is a Pro feature." } ?? "Every tool you need to reclaim space — safely.")
                        .foregroundStyle(.white.opacity(0.9))
                }
                .padding(.vertical, 22)
            }
            .frame(height: 140)

            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    LazyVGrid(columns: columns, alignment: .leading, spacing: 12) {
                        ForEach(ProFeature.allCases) { feature in
                            HStack(alignment: .top, spacing: 10) {
                                Image(systemName: feature.symbolName)
                                    .font(.title3)
                                    .foregroundStyle(feature == highlighted ? Color.purple : Color.accentColor)
                                    .frame(width: 26)
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(feature.title).fontWeight(.semibold)
                                    Text(feature.detail).font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                                }
                            }
                            .padding(10)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .background(feature == highlighted ? Color.purple.opacity(0.10) : Color.clear, in: RoundedRectangle(cornerRadius: 8))
                        }
                    }

                    HStack(alignment: .firstTextBaseline, spacing: 4) {
                        Text(ProConfiguration.priceText).font(.system(size: 30, weight: .bold, design: .rounded))
                        Text("/ \(ProConfiguration.billingPeriod)").foregroundStyle(.secondary)
                        Spacer()
                        Text("Less than $8.50 a month · Billed yearly in USD").font(.caption).foregroundStyle(.secondary)
                    }

                    statusBanner(pro.status)

                    VStack(spacing: 8) {
                        if case .free(let trialAvailable) = pro.status, trialAvailable {
                            Button {
                                pro.startTrial()
                                dismiss()
                            } label: {
                                Text("Start \(ProConfiguration.trialDays)-Day Free Trial").frame(maxWidth: .infinity)
                            }
                            .buttonStyle(.borderedProminent).controlSize(.large)
                            Text("No account or card needed for the trial.").font(.caption).foregroundStyle(.secondary)
                        }
                        Button {
                            pro.openCheckout()
                            showKeyField = true
                        } label: {
                            Text("Subscribe — \(ProConfiguration.priceText)/\(ProConfiguration.billingPeriod)").frame(maxWidth: .infinity)
                        }
                        .buttonStyle(.bordered).controlSize(.large)
                        .disabled(!ProConfiguration.isConfigured)
                    }

                    DisclosureGroup("I already have a license key", isExpanded: $showKeyField) {
                        HStack {
                            TextField("XXXXXXXX-XXXX-XXXX-XXXX-XXXXXXXXXXXX", text: $licenseKey)
                                .textFieldStyle(.roundedBorder)
                                .font(.body.monospaced())
                                .onSubmit { activate() }
                            Button("Activate") { activate() }.disabled(pro.isWorking || licenseKey.isEmpty)
                            if pro.isWorking { ProgressView().controlSize(.small) }
                        }
                        .padding(.top, 6)
                        Text("After purchase, your key arrives by email. Activation sends only the key to the license server — never any file information.")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    if let error = pro.lastError {
                        Label(error, systemImage: "exclamationmark.triangle.fill").foregroundStyle(.orange).font(.callout)
                    }

                    Divider()
                    HStack(spacing: 14) {
                        Label("Cancel anytime", systemImage: "arrow.uturn.backward.circle")
                        Label("14-day refund", systemImage: "dollarsign.arrow.circlepath")
                        Label("Works offline", systemImage: "wifi.slash")
                    }
                    .font(.caption).foregroundStyle(.secondary)
                    HStack {
                        Link("Terms", destination: ProConfiguration.termsURL)
                        Link("Privacy", destination: ProConfiguration.privacyURL)
                        Spacer()
                        Text("Secure checkout by Lemon Squeezy").font(.caption2).foregroundStyle(.tertiary)
                    }
                    .font(.caption)
                }
                .padding(22)
            }
            HStack {
                Spacer()
                Button("Not Now") { dismiss() }.keyboardShortcut(.cancelAction)
            }
            .padding(.horizontal, 22).padding(.vertical, 12)
            .background(.bar)
        }
        .frame(width: 600, height: 680)
        .onChange(of: pro.isPro) { _, isPro in if isPro { dismiss() } }
    }

    private func activate() {
        Task { await model.pro.activate(key: licenseKey) }
    }

    @ViewBuilder
    private func statusBanner(_ status: ProStatus) -> some View {
        switch status {
        case .trial(let endsAt):
            Label("Your free trial ends \(endsAt.formatted(.relative(presentation: .named))).", systemImage: "clock")
                .foregroundStyle(.purple)
        case .free(let trialAvailable) where !trialAvailable:
            Label("Your free trial has ended.", systemImage: "clock.badge.xmark").foregroundStyle(.secondary)
        case .lapsed(let license):
            Label("Your subscription is \(license.status). Renew to continue using Pro.", systemImage: "exclamationmark.circle")
                .foregroundStyle(.orange)
        default:
            EmptyView()
        }
    }
}

/// Replaces a Pro-only screen for free users, with a preview of what it does.
struct ProLockedView: View {
    @Environment(AppModel.self) private var model
    var feature: ProFeature

    var body: some View {
        VStack(spacing: 16) {
            ZStack {
                Circle().fill(LinearGradient(colors: [.purple.opacity(0.25), .blue.opacity(0.25)], startPoint: .top, endPoint: .bottom))
                    .frame(width: 96, height: 96)
                Image(systemName: feature.symbolName).font(.system(size: 40, weight: .medium)).foregroundStyle(.purple)
            }
            HStack(spacing: 8) {
                Text(feature.title).font(.title.weight(.semibold))
                ProBadge()
            }
            Text(feature.detail).font(.title3).foregroundStyle(.secondary).multilineTextAlignment(.center).frame(maxWidth: 460)
            HStack(spacing: 12) {
                if case .free(let available) = model.pro.status, available {
                    Button("Start \(ProConfiguration.trialDays)-Day Free Trial") { model.pro.startTrial() }
                        .buttonStyle(.borderedProminent).controlSize(.large)
                }
                Button("See Pro Plans") { model.showPaywall(feature) }.controlSize(.large)
            }
        }
        .padding(40)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

/// Wraps a Pro-only screen: shows the content when unlocked, the locked view otherwise.
struct ProGate<Content: View>: View {
    @Environment(AppModel.self) private var model
    var feature: ProFeature
    @ViewBuilder var content: () -> Content

    var body: some View {
        if model.pro.isUnlocked(feature) {
            content()
        } else {
            ProLockedView(feature: feature)
        }
    }
}

/// Compact upgrade/status card at the bottom of the sidebar.
struct SidebarProCard: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        switch model.pro.status {
        case .pro:
            Label("SpaceBridge Pro", systemImage: "checkmark.seal.fill")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.purple)
        case .trial:
            Button { model.showPaywall() } label: {
                HStack {
                    Image(systemName: "clock")
                    Text("Pro trial · \(model.pro.trialDaysLeft ?? 0) days left").font(.caption.weight(.semibold))
                    Spacer()
                }
            }
            .buttonStyle(.plain).foregroundStyle(.purple)
        case .free, .lapsed:
            Button { model.showPaywall() } label: {
                HStack(spacing: 8) {
                    Image(systemName: "sparkles")
                    VStack(alignment: .leading, spacing: 1) {
                        Text("Upgrade to Pro").font(.caption.weight(.bold))
                        Text("Cleanup, duplicates & more").font(.caption2).opacity(0.85)
                    }
                    Spacer()
                }
                .foregroundStyle(.white)
                .padding(10)
                .background(LinearGradient(colors: [.purple, .blue], startPoint: .topLeading, endPoint: .bottomTrailing),
                            in: RoundedRectangle(cornerRadius: 10, style: .continuous))
            }
            .buttonStyle(.plain)
        }
    }
}

/// Pro section for Settings.
struct ProSettingsSection: View {
    @Environment(AppModel.self) private var model
    @State private var confirmDeactivate = false

    var body: some View {
        let pro = model.pro
        Section("SpaceBridge Pro") {
            switch pro.status {
            case .pro(let license):
                LabeledContent("Status", value: "Active")
                LabeledContent("License", value: license.maskedKey)
                if let email = license.customerEmail { LabeledContent("Email", value: email) }
                if let expires = license.expiresAt { LabeledContent("Renews / expires", value: expires.formatted(date: .long, time: .omitted)) }
                LabeledContent("Last verified", value: license.lastValidated.formatted(.relative(presentation: .named)))
                HStack {
                    Button("Manage Subscription") { pro.openCustomerPortal() }
                    Button("Deactivate This Mac…") { confirmDeactivate = true }
                }
            case .trial(let endsAt):
                LabeledContent("Status", value: "Free trial — ends \(endsAt.formatted(date: .abbreviated, time: .omitted))")
                Button("Subscribe…") { model.showPaywall() }
            case .free:
                LabeledContent("Status", value: "Free")
                Button("Upgrade to Pro…") { model.showPaywall() }
            case .lapsed(let license):
                LabeledContent("Status", value: "Subscription \(license.status)")
                HStack {
                    Button("Renew…") { pro.openCheckout() }
                    Button("Check Again") { Task { await pro.validateIfNeeded(force: true) } }
                }
            }
            if let error = pro.lastError { Text(error).font(.caption).foregroundStyle(.orange) }
        }
        .confirmationDialog("Deactivate SpaceBridge Pro on this Mac?", isPresented: $confirmDeactivate) {
            Button("Deactivate", role: .destructive) { Task { await pro.deactivate() } }
        } message: {
            Text("You can activate the same license on another Mac. Your scan data isn't affected.")
        }
    }
}
