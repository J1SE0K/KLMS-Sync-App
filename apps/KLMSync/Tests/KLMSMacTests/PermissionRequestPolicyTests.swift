import EventKit
@testable import KLMSMac
import UserNotifications
import XCTest

final class PermissionRequestPolicyTests: XCTestCase {
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
