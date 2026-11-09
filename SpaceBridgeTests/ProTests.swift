import XCTest
@testable import SpaceBridge

/// Fake license server so tests never touch the network.
private final class MockLicenseService: LicenseService, @unchecked Sendable {
    var activateResult: Result<LicenseInfo, LicenseError> = .failure(.invalidKey(""))
    var validateResult: Result<LicenseInfo, LicenseError> = .failure(.network("offline"))

    func activate(key: String, instanceName: String) async throws -> LicenseInfo { try activateResult.get() }
    func validate(_ license: LicenseInfo) async throws -> LicenseInfo { try validateResult.get() }
    func deactivate(_ license: LicenseInfo) async throws {}
}

@MainActor
final class ProStoreTests: XCTestCase {
    private var keychain: KeychainStore!

    override func setUp() async throws {
        keychain = KeychainStore(service: "com.geniusbridge.SpaceBridge.tests.\(UUID().uuidString)")
    }

    override func tearDown() async throws {
        keychain.remove("license")
        keychain.remove("trial-start")
    }

    private func license(status: String = "active", validated: Date = Date(), expires: Date? = nil) -> LicenseInfo {
        LicenseInfo(key: "ABCD-1234-EFGH-5678", instanceID: "i1", status: status, customerEmail: "a@b.com",
                    productName: "SpaceBridge Pro", expiresAt: expires, lastValidated: validated)
    }

    func testFreeByDefaultWithTrialAvailable() {
        let store = ProStore(keychain: keychain, service: MockLicenseService())
        XCTAssertEqual(store.status, .free(trialAvailable: true))
        XCTAssertFalse(store.isPro)
    }

    func testTrialUnlocksThenExpiresOnce() {
        var clock = Date(timeIntervalSince1970: 1_800_000_000)
        let store = ProStore(keychain: keychain, service: MockLicenseService(), now: { clock })
        store.startTrial()
        XCTAssertTrue(store.isPro)
        XCTAssertEqual(store.trialDaysLeft, ProConfiguration.trialDays)

        clock = clock.addingTimeInterval(TimeInterval(ProConfiguration.trialDays + 1) * 86_400)
        store.refreshLocalStatus()
        XCTAssertEqual(store.status, .free(trialAvailable: false), "a trial can't be restarted")
        store.startTrial()
        XCTAssertFalse(store.isPro)
    }

    func testActiveLicenseIsPro() {
        keychain.setValue(license(), for: "license")
        let store = ProStore(keychain: keychain, service: MockLicenseService())
        XCTAssertTrue(store.isPro)
    }

    func testExpiredOrDisabledLicenseIsNotPro() {
        keychain.setValue(license(status: "expired"), for: "license")
        XCTAssertFalse(ProStore(keychain: keychain, service: MockLicenseService()).isPro)
        keychain.setValue(license(expires: Date().addingTimeInterval(-60)), for: "license")
        XCTAssertFalse(ProStore(keychain: keychain, service: MockLicenseService()).isPro)
    }

    func testOfflineGracePeriod() async {
        // Validated 20 days ago, server unreachable: still Pro.
        keychain.setValue(license(validated: Date().addingTimeInterval(-20 * 86_400)), for: "license")
        let store = ProStore(keychain: keychain, service: MockLicenseService())
        await store.validateIfNeeded()
        XCTAssertTrue(store.isPro)
        // Not verified for 31 days: Pro pauses until the next successful check.
        keychain.setValue(license(validated: Date().addingTimeInterval(-31 * 86_400)), for: "license")
        store.refreshLocalStatus()
        XCTAssertFalse(store.isPro)
    }

    func testServerRejectionRevokes() async {
        keychain.setValue(license(validated: Date().addingTimeInterval(-8 * 86_400)), for: "license")
        let service = MockLicenseService()
        service.validateResult = .failure(.invalidKey("revoked"))
        let store = ProStore(keychain: keychain, service: service)
        await store.validateIfNeeded()
        XCTAssertFalse(store.isPro)
    }
}

final class ProSupportTests: XCTestCase {
    func testAdvancedSearchDetection() {
        XCTAssertFalse(SearchParser.parse("*.zip").isAdvanced)
        XCTAssertFalse(SearchParser.parse("node_modules").isAdvanced)
        XCTAssertTrue(SearchParser.parse("size > 1 GB").isAdvanced)
        XCTAssertTrue(SearchParser.parse("modified > 1 year ago").isAdvanced)
        XCTAssertTrue(SearchParser.parse("in:Downloads report").isAdvanced)
    }

    func testCSVEscaping() {
        XCTAssertEqual(ReportExporter.escape("plain"), "plain")
        XCTAssertEqual(ReportExporter.escape("a,b"), "\"a,b\"")
        XCTAssertEqual(ReportExporter.escape("say \"hi\""), "\"say \"\"hi\"\"\"")
        XCTAssertEqual(ReportExporter.escape("=SUM(A1)"), "'=SUM(A1)", "formula injection is neutralized")
    }

    func testMaskedKey() {
        let info = LicenseInfo(key: "ABCD-1234-EFGH-5678", instanceID: "x", status: "active", lastValidated: Date())
        XCTAssertEqual(info.maskedKey, "ABCD••••5678")
    }
}
