#!/usr/bin/env swift

import AppKit
import ApplicationServices
import Darwin
import Foundation

private enum SmokeFailure: Error, CustomStringConvertible {
    case accessibilityPermissionMissing
    case appMissing
    case dashboardMissing
    case fullSyncMissing
    case fullSyncDisabled
    case cancelMissing
    case progressMissing
    case cancelDidNotClear

    var description: String {
        switch self {
        case .accessibilityPermissionMissing:
            return "Accessibility permission is not granted for Terminal/Codex."
        case .appMissing:
            return "KLMS Sync is not running."
        case .dashboardMissing:
            return "Could not open the dashboard window."
        case .fullSyncMissing:
            return "Could not find the full sync button."
        case .fullSyncDisabled:
            return "The full sync button is disabled."
        case .cancelMissing:
            return "Full sync did not expose the cancel button."
        case .progressMissing:
            return "Running sync did not expose the progress indicator."
        case .cancelDidNotClear:
            return "Cancel did not clear the running command in time."
        }
    }
}

private let environment = ProcessInfo.processInfo.environment
private let bundleID = environment["KLMS_MAC_BUNDLE_ID"] ?? "com.local.KLMSync"
private let appName = environment["KLMS_MAC_APP_NAME"] ?? "KLMS Sync"
private let timeout = TimeInterval(environment["KLMS_MAC_AX_TIMEOUT_SECONDS"] ?? "10.0") ?? 10.0

do {
    try runSmoke()
} catch {
    FileHandle.standardError.write(Data("smoke failed: \(error)\n".utf8))
    exit(1)
}

private func runSmoke() throws {
    let trustedOptions = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: false] as CFDictionary
    guard AXIsProcessTrustedWithOptions(trustedOptions) else {
        throw SmokeFailure.accessibilityPermissionMissing
    }

    guard let app = findRunningApp() else {
        throw SmokeFailure.appMissing
    }
    let appElement = AXUIElementCreateApplication(app.processIdentifier)
    requestDashboardWindowReopen()

    guard let dashboard = waitForElement(withIdentifier: "workspace-dashboard", in: appElement, timeout: timeout) else {
        throw SmokeFailure.dashboardMissing
    }
    _ = AXUIElementPerformAction(dashboard, kAXPressAction as CFString)
    _ = waitForElement(withIdentifier: "workspace-content-dashboard", in: appElement, timeout: 2)

    guard let fullSync = waitForCommandButton(
        identifier: "command-fullSync",
        titleContains: "전체 동기화",
        in: appElement,
        timeout: timeout
    ) else {
        throw SmokeFailure.fullSyncMissing
    }
    if boolAttribute(fullSync, kAXEnabledAttribute as CFString) == false {
        throw SmokeFailure.fullSyncDisabled
    }
    _ = AXUIElementPerformAction(fullSync, kAXPressAction as CFString)

    guard let cancel = waitForElement(withIdentifier: "command-cancel", in: appElement, timeout: timeout) else {
        throw SmokeFailure.cancelMissing
    }
    guard waitForRunningProgress(in: appElement, timeout: timeout) else {
        _ = AXUIElementPerformAction(cancel, kAXPressAction as CFString)
        throw SmokeFailure.progressMissing
    }

    _ = AXUIElementPerformAction(cancel, kAXPressAction as CFString)
    let cleared = waitUntil(timeout: timeout) {
        waitForElement(withIdentifier: "command-cancel", in: appElement, timeout: 0.1) == nil
    }
    guard cleared else {
        throw SmokeFailure.cancelDidNotClear
    }

    print("ok: full sync shows running progress and can be cancelled")
}

private func findRunningApp() -> NSRunningApplication? {
    let runningByBundleID = NSRunningApplication.runningApplications(withBundleIdentifier: bundleID)
    let runningByName = NSWorkspace.shared.runningApplications.filter { app in
        app.localizedName == appName || app.executableURL?.lastPathComponent == "KLMSMac"
    }
    return (runningByBundleID + runningByName).first(where: { !$0.isTerminated })
}

private func requestDashboardWindowReopen() {
    let escapedAppName = appName.replacingOccurrences(of: "\"", with: "\\\"")
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
    process.arguments = ["-e", "tell application \"\(escapedAppName)\" to reopen"]
    process.standardOutput = Pipe()
    process.standardError = Pipe()
    try? process.run()
    process.waitUntilExit()
}

private func waitForElement(
    withIdentifier identifier: String,
    in root: AXUIElement,
    timeout: TimeInterval
) -> AXUIElement? {
    waitForElement(in: root, timeout: timeout) {
        stringAttribute($0, "AXIdentifier" as CFString) == identifier
    }
}

private func waitForCommandButton(
    identifier: String,
    titleContains title: String,
    in root: AXUIElement,
    timeout: TimeInterval
) -> AXUIElement? {
    if let exact = waitForElement(in: root, timeout: timeout, where: { element in
        guard stringAttribute(element, kAXRoleAttribute as CFString) == kAXButtonRole as String else {
            return false
        }
        return elementOrDescendantMatches(element, maxDepth: 6) { candidate in
            stringAttribute(candidate, "AXIdentifier" as CFString) == identifier
        }
    }) {
        return exact
    }

    return waitForElement(in: root, timeout: timeout) { element in
        guard stringAttribute(element, kAXRoleAttribute as CFString) == kAXButtonRole as String else {
            return false
        }
        return elementOrDescendantMatches(element, maxDepth: 6) { candidate in
            if stringAttribute(candidate, "AXIdentifier" as CFString) == identifier {
                return true
            }
            let titleAttributes = [
                kAXTitleAttribute as CFString,
                kAXDescriptionAttribute as CFString,
                kAXValueAttribute as CFString,
            ]
            return titleAttributes.contains { key in
                stringAttribute(candidate, key)?.contains(title) == true
            }
        }
    }
}

private func elementOrDescendantMatches(
    _ root: AXUIElement,
    maxDepth: Int,
    where predicate: (AXUIElement) -> Bool
) -> Bool {
    if predicate(root) {
        return true
    }
    guard maxDepth > 0 else {
        return false
    }
    return arrayAttribute(root, kAXChildrenAttribute as CFString).contains { child in
        elementOrDescendantMatches(child, maxDepth: maxDepth - 1, where: predicate)
    }
}

private func waitForRunningProgress(in root: AXUIElement, timeout: TimeInterval) -> Bool {
    waitForElement(in: root, timeout: timeout) { element in
        stringAttribute(element, "AXIdentifier" as CFString) == "running-progress"
            || stringAttribute(element, kAXDescriptionAttribute as CFString) == "동기화 진행률"
            || stringAttribute(element, kAXTitleAttribute as CFString) == "동기화 진행률"
            || stringAttribute(element, kAXValueAttribute as CFString)?.contains("/") == true
    } != nil
}

private func waitForElement(
    in root: AXUIElement,
    timeout: TimeInterval,
    where predicate: @escaping (AXUIElement) -> Bool
) -> AXUIElement? {
    let deadline = Date().addingTimeInterval(timeout)
    repeat {
        if let element = findElement(in: root, maxDepth: 32, maxNodes: 40_000, where: predicate) {
            return element
        }
        Thread.sleep(forTimeInterval: 0.06)
    } while Date() < deadline
    return nil
}

private func waitUntil(timeout: TimeInterval, _ predicate: () -> Bool) -> Bool {
    let deadline = Date().addingTimeInterval(timeout)
    repeat {
        if predicate() {
            return true
        }
        Thread.sleep(forTimeInterval: 0.06)
    } while Date() < deadline
    return false
}

private func findElement(
    in root: AXUIElement,
    maxDepth: Int,
    maxNodes: Int,
    where predicate: (AXUIElement) -> Bool
) -> AXUIElement? {
    var queue: [(AXUIElement, Int)] = [(root, 0)]
    var visited = 0
    while !queue.isEmpty, visited < maxNodes {
        let (element, depth) = queue.removeFirst()
        visited += 1
        if predicate(element) {
            return element
        }
        guard depth < maxDepth else {
            continue
        }
        arrayAttribute(element, kAXChildrenAttribute as CFString).forEach {
            queue.append(($0, depth + 1))
        }
    }
    return nil
}

private func stringAttribute(_ element: AXUIElement, _ key: CFString) -> String? {
    var value: CFTypeRef?
    guard AXUIElementCopyAttributeValue(element, key, &value) == .success else {
        return nil
    }
    return value as? String
}

private func boolAttribute(_ element: AXUIElement, _ key: CFString) -> Bool? {
    var value: CFTypeRef?
    guard AXUIElementCopyAttributeValue(element, key, &value) == .success else {
        return nil
    }
    return value as? Bool
}

private func arrayAttribute(_ element: AXUIElement, _ key: CFString) -> [AXUIElement] {
    var value: CFTypeRef?
    guard AXUIElementCopyAttributeValue(element, key, &value) == .success else {
        return []
    }
    return value as? [AXUIElement] ?? []
}
