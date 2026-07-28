import EventKit
@testable import KLMSMac
import UserNotifications
import XCTest

final class PermissionRequestPolicyTests: XCTestCase {
    func testIsolatedQAProfileAcceptsOnlyDedicatedLoopbackSandbox() throws {
        let root = URL(
            fileURLWithPath: "/private/tmp/klms-isolated-qa-\(UUID().uuidString)",
            isDirectory: true
        )
        defer { try? FileManager.default.removeItem(at: root) }
        let clientToken = String(repeating: "a", count: 64)
        let workerToken = String(repeating: "b", count: 64)
        let environment = [
            KLMSMacIsolatedQAProfile.environmentFlag: "1",
            KLMSMacIsolatedQAProfile.rootEnvironmentKey: root.path,
            KLMSMacIsolatedQAProfile.relayURLEnvironmentKey: "http://127.0.0.1:18484",
            KLMSMacIsolatedQAProfile.clientTokenEnvironmentKey: clientToken,
            KLMSMacIsolatedQAProfile.workerTokenEnvironmentKey: workerToken,
        ]

        let profile = try XCTUnwrap(
            KLMSMacIsolatedQAProfile.current(
                bundleIdentifier: "com.local.KLMSync.QA.Tests",
                environment: environment
            )
        )
        profile.record(event: "profile-test", revision: 7)

        let eventData = try Data(contentsOf: profile.eventLogURL)
        let event = try XCTUnwrap(
            try JSONSerialization.jsonObject(with: eventData) as? [String: Any]
        )
        XCTAssertEqual(event["event"] as? String, "profile-test")
        XCTAssertEqual(event["revision"] as? Int, 7)
        XCTAssertFalse(String(decoding: eventData, as: UTF8.self).contains(clientToken))
        XCTAssertFalse(String(decoding: eventData, as: UTF8.self).contains(workerToken))
        let attributes = try FileManager.default.attributesOfItem(atPath: profile.eventLogURL.path)
        XCTAssertEqual((attributes[.posixPermissions] as? NSNumber)?.intValue, 0o600)
    }

    func testIsolatedQAProfileCanValidateTheContainingQAAppBundle() throws {
        let root = URL(
            fileURLWithPath: "/private/tmp/klms-isolated-qa-\(UUID().uuidString)",
            isDirectory: true
        )
        let appURL = root.appendingPathComponent("Fixture.app", isDirectory: true)
        let executableURL = appURL.appendingPathComponent("Contents/MacOS/KLMSMac")
        let infoURL = appURL.appendingPathComponent("Contents/Info.plist")
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(
            at: executableURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        let bundleIdentifier = "com.local.KLMSync.QA.Fixture"
        let infoData = try PropertyListSerialization.data(
            fromPropertyList: [
                "CFBundleIdentifier": bundleIdentifier,
                "CFBundleExecutable": "KLMSMac",
                "CFBundlePackageType": "APPL",
            ],
            format: .xml,
            options: 0
        )
        try infoData.write(to: infoURL)
        try Data().write(to: executableURL)
        var environment = [
            KLMSMacIsolatedQAProfile.environmentFlag: "1",
            KLMSMacIsolatedQAProfile.bundleIdentifierEnvironmentKey: bundleIdentifier,
            KLMSMacIsolatedQAProfile.rootEnvironmentKey: root.path,
            KLMSMacIsolatedQAProfile.relayURLEnvironmentKey: "http://127.0.0.1:18484",
            KLMSMacIsolatedQAProfile.clientTokenEnvironmentKey: String(repeating: "a", count: 64),
            KLMSMacIsolatedQAProfile.workerTokenEnvironmentKey: String(repeating: "b", count: 64),
        ]

        XCTAssertEqual(
            KLMSMacIsolatedQAProfile.appBundleIdentifier(executablePath: executableURL.path),
            bundleIdentifier
        )
        XCTAssertNil(
            KLMSMacIsolatedQAProfile.validationIssue(
                bundleIdentifier: nil,
                environment: environment,
                executablePath: executableURL.path
            )
        )
        XCTAssertNotNil(
            KLMSMacIsolatedQAProfile.current(
                bundleIdentifier: nil,
                environment: environment,
                executablePath: executableURL.path
            )
        )
        environment[KLMSMacIsolatedQAProfile.bundleIdentifierEnvironmentKey] =
            "com.local.KLMSync.QA.Other"
        XCTAssertNil(
            KLMSMacIsolatedQAProfile.current(
                bundleIdentifier: nil,
                environment: environment,
                executablePath: executableURL.path
            )
        )
    }

    func testIsolatedQAProfileRejectsProductionAndEscapingInputs() {
        let clientToken = String(repeating: "a", count: 64)
        let workerToken = String(repeating: "b", count: 64)
        let baseEnvironment = [
            KLMSMacIsolatedQAProfile.environmentFlag: "1",
            KLMSMacIsolatedQAProfile.rootEnvironmentKey: "/private/tmp/klms-isolated-qa-valid",
            KLMSMacIsolatedQAProfile.relayURLEnvironmentKey: "http://localhost:18484",
            KLMSMacIsolatedQAProfile.clientTokenEnvironmentKey: clientToken,
            KLMSMacIsolatedQAProfile.workerTokenEnvironmentKey: workerToken,
        ]

        XCTAssertNil(
            KLMSMacIsolatedQAProfile.current(
                bundleIdentifier: "com.local.KLMSync",
                environment: baseEnvironment
            )
        )
        for (key, invalidValue) in [
            (KLMSMacIsolatedQAProfile.rootEnvironmentKey, "/private/tmp/klms-isolated-qa-valid/nested"),
            (KLMSMacIsolatedQAProfile.rootEnvironmentKey, "/tmp/klms-isolated-qa-valid"),
            (KLMSMacIsolatedQAProfile.relayURLEnvironmentKey, "http://example.com:18484"),
            (KLMSMacIsolatedQAProfile.relayURLEnvironmentKey, "http://user:pass@127.0.0.1:18484"),
            (KLMSMacIsolatedQAProfile.relayURLEnvironmentKey, "http://127.0.0.1:18484/base"),
            (KLMSMacIsolatedQAProfile.relayURLEnvironmentKey, "http://127.0.0.1:18484?token=secret"),
            (KLMSMacIsolatedQAProfile.clientTokenEnvironmentKey, "too-short"),
            (KLMSMacIsolatedQAProfile.workerTokenEnvironmentKey, clientToken),
        ] {
            var environment = baseEnvironment
            environment[key] = invalidValue
            XCTAssertNil(
                KLMSMacIsolatedQAProfile.current(
                    bundleIdentifier: "com.local.KLMSync.QA.Tests",
                    environment: environment
                ),
                "Expected isolated QA profile to reject \(key)"
            )
        }
    }

    func testAutomaticPermissionOnboardingIsIndependentOfPayloadVersionAndRunsOnce() {
        XCTAssertTrue(
            KLMSMacPermissionRequestPolicy.shouldAutomaticallyRequest(
                hasAttempted: false,
                legacyVersion: nil
            )
        )
        XCTAssertFalse(
            KLMSMacPermissionRequestPolicy.shouldAutomaticallyRequest(
                hasAttempted: true,
                legacyVersion: nil
            )
        )
        XCTAssertFalse(
            KLMSMacPermissionRequestPolicy.shouldAutomaticallyRequest(
                hasAttempted: false,
                legacyVersion: "legacy-payload-version"
            )
        )
    }

    func testNotificationPermissionOnlyRequestsWhileUndetermined() {
        XCTAssertEqual(
            KLMSMacPermissionRequestPolicy.notificationDecision(.notDetermined),
            .request
        )
        XCTAssertEqual(
            KLMSMacPermissionRequestPolicy.notificationDecision(.authorized),
            .granted
        )
        XCTAssertEqual(
            KLMSMacPermissionRequestPolicy.notificationDecision(.denied),
            .unavailable
        )
    }

    func testAccessibilityPermissionPromptIsOffAfterItsFirstAttempt() {
        XCTAssertTrue(
            KLMSMacPermissionRequestPolicy.shouldPromptForAccessibility(
                isTrusted: false,
                hasAttempted: false
            )
        )
        XCTAssertFalse(
            KLMSMacPermissionRequestPolicy.shouldPromptForAccessibility(
                isTrusted: false,
                hasAttempted: true
            )
        )
        XCTAssertFalse(
            KLMSMacPermissionRequestPolicy.shouldPromptForAccessibility(
                isTrusted: true,
                hasAttempted: false
            )
        )
        XCTAssertFalse(
            KLMSMacPermissionRequestPolicy.accessibilityPromptWasAttempted(
                dedicatedAttempt: false,
                automaticAttempt: true,
                legacyVersion: nil,
                isAutomaticOnboarding: true
            ),
            "The current automatic onboarding attempt must still be allowed to present its one prompt."
        )
        XCTAssertTrue(
            KLMSMacPermissionRequestPolicy.accessibilityPromptWasAttempted(
                dedicatedAttempt: false,
                automaticAttempt: true,
                legacyVersion: nil,
                isAutomaticOnboarding: false
            ),
            "A manual retry after the legacy automatic onboarding prompt must not present it again."
        )
        XCTAssertTrue(
            KLMSMacPermissionRequestPolicy.accessibilityPromptWasAttempted(
                dedicatedAttempt: false,
                automaticAttempt: false,
                legacyVersion: "legacy-version",
                isAutomaticOnboarding: false
            )
        )
    }

    func testEventKitPermissionOnlyRequestsWhileUndetermined() {
        XCTAssertEqual(
            KLMSMacPermissionRequestPolicy.eventKitDecision(.notDetermined),
            .request
        )
        XCTAssertEqual(
            KLMSMacPermissionRequestPolicy.eventKitDecision(.fullAccess),
            .granted
        )
        XCTAssertEqual(
            KLMSMacPermissionRequestPolicy.eventKitDecision(.denied),
            .unavailable
        )
        XCTAssertEqual(
            KLMSMacPermissionRequestPolicy.eventKitDecision(.restricted),
            .unavailable
        )
    }

    func testAutomaticAttemptIsPersistedBeforeAsyncPermissionWorkAndDeliveryNeverRequests() throws {
        let source = try String(contentsOf: modelSourceURL(), encoding: .utf8)
        let requestBlock = try sourceSlice(
            source,
            from: "private func requestAppPermissions(markAutomatic: Bool) async",
            to: "func createBackup()"
        )
        let attemptWrite = try XCTUnwrap(
            requestBlock.range(of: "UserDefaults.standard.set(true, forKey: Self.automaticPermissionRequestAttemptedKey)")
        )
        let firstSuspension = try XCTUnwrap(requestBlock.range(of: "await Task.yield()"))
        XCTAssertLessThan(attemptWrite.lowerBound, firstSuspension.lowerBound)
        XCTAssertTrue(requestBlock.contains("guard !isRequestingAppPermissions else { return }"))

        XCTAssertEqual(
            source.components(separatedBy: "requestAuthorization(options: [.alert, .sound])").count - 1,
            1,
            "Only the status-gated onboarding helper may invoke the notification authorization request."
        )
        let notificationDelivery = try sourceSlice(
            source,
            from: "private func notifyAuthDigits",
            to: "private func recordServerRelayFileAccessRequest"
        )
        XCTAssertFalse(notificationDelivery.contains("requestAuthorization"))
        XCTAssertEqual(
            notificationDelivery.components(separatedBy: "guard await hasNotificationPermission() else { return }").count - 1,
            3
        )

        let accessibilityRequest = try sourceSlice(
            source,
            from: "private static func requestAccessibilityPermissionOnce",
            to: "nonisolated private static func runNativeNoticeHelperPermissionProbe"
        )
        let accessibilityAttemptWrite = try XCTUnwrap(
            accessibilityRequest.range(of: "defaults.set(true, forKey: accessibilityPermissionPromptAttemptedKey)")
        )
        let promptingCheck = try XCTUnwrap(
            accessibilityRequest.range(of: "AXIsProcessTrustedWithOptions([promptKey: true] as CFDictionary)")
        )
        XCTAssertLessThan(accessibilityAttemptWrite.lowerBound, promptingCheck.lowerBound)
        XCTAssertTrue(accessibilityRequest.contains("let checkOnlyOptions = [promptKey: false] as CFDictionary"))
    }

    private func modelSourceURL() -> URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("Sources/KLMSMac/KLMSMacModel.swift")
    }

    private func sourceSlice(_ source: String, from start: String, to end: String) throws -> String {
        let startRange = try XCTUnwrap(source.range(of: start))
        let endRange = try XCTUnwrap(source.range(of: end, range: startRange.upperBound..<source.endIndex))
        return String(source[startRange.lowerBound..<endRange.lowerBound])
    }
}
