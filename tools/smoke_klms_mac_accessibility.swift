#!/usr/bin/env swift

import AppKit
import ApplicationServices
import Foundation

private enum SmokeFailure: Error, CustomStringConvertible {
    case accessibilityPermissionMissing
    case appNotRunning(bundleID: String, appName: String)
    case dashboardOpenControlMissing
    case dashboardOpenFailed(AXError)
    case workspaceButtonMissing(String)
    case settingsTabMissing(String)
    case pressFailed(identifier: String, AXError)
    case selectedValueMissing(String)
    case expectedTextMissing(String)

    var description: String {
        switch self {
        case .accessibilityPermissionMissing:
            return "Accessibility permission is not granted for Terminal/Codex. Enable it in System Settings > Privacy & Security > Accessibility."
        case let .appNotRunning(bundleID, appName):
            return "KLMS Mac app is not running. Expected bundle id '\(bundleID)' or app name '\(appName)'."
        case .dashboardOpenControlMissing:
            return "Could not find the menu item that opens the KLMS dashboard window."
        case let .dashboardOpenFailed(error):
            return "Could not open the KLMS dashboard window from the menu bar: \(error)."
        case let .workspaceButtonMissing(identifier):
            return "Could not find workspace button with accessibility identifier '\(identifier)'."
        case let .settingsTabMissing(identifier):
            return "Could not find settings tab with accessibility identifier '\(identifier)'."
        case let .pressFailed(identifier, error):
            return "Could not press button '\(identifier)': \(error)."
        case let .selectedValueMissing(identifier):
            return "Button '\(identifier)' did not expose the selected accessibility value after navigation."
        case let .expectedTextMissing(text):
            return "Expected text '\(text)' did not appear after navigation."
        }
    }
}

private let environment = ProcessInfo.processInfo.environment
private let bundleID = environment["KLMS_MAC_BUNDLE_ID"] ?? "com.local.KLMSync"
private let appName = environment["KLMS_MAC_APP_NAME"] ?? "KLMS Sync"
private let navigationDelay = TimeInterval(environment["KLMS_MAC_AX_NAVIGATION_DELAY_SECONDS"] ?? "0.60") ?? 0.60
private let timeout = TimeInterval(environment["KLMS_MAC_AX_TIMEOUT_SECONDS"] ?? "5.0") ?? 5.0

private let trustedOptions = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: false] as CFDictionary
guard AXIsProcessTrustedWithOptions(trustedOptions) else {
    throw SmokeFailure.accessibilityPermissionMissing
}

private let runningByBundleID = NSRunningApplication.runningApplications(withBundleIdentifier: bundleID)
private let runningByName = NSWorkspace.shared.runningApplications.filter { app in
    app.localizedName == appName || app.executableURL?.lastPathComponent == "KLMSMac"
}
guard let app = (runningByBundleID + runningByName).first(where: { !$0.isTerminated }) else {
    throw SmokeFailure.appNotRunning(bundleID: bundleID, appName: appName)
}

let appElement = AXUIElementCreateApplication(app.processIdentifier)

try openDashboardWindowIfNeeded(appElement: appElement)

try verifyWorkspaceNavigation(
    appElement: appElement,
    identifier: "workspace-settings",
    expectedText: "화면/앱"
)
try verifySettingsTabNavigation(
    appElement: appElement,
    identifier: "settings-files",
    expectedText: "파일 확인"
)
try verifySettingsTabNavigation(
    appElement: appElement,
    identifier: "settings-app",
    expectedText: "바로 반영되는 설정"
)
try verifyWorkspaceNavigation(
    appElement: appElement,
    identifier: "workspace-dashboard",
    expectedText: "대시보드"
)

print("ok: KLMS Mac workspace accessibility navigation is responsive")

private func openDashboardWindowIfNeeded(appElement: AXUIElement) throws {
    if waitForElement(withIdentifier: "workspace-dashboard", in: appElement, timeout: 0.4) != nil {
        return
    }

    requestDashboardWindowReopen()
    if waitForElement(withIdentifier: "workspace-dashboard", in: appElement, timeout: timeout) != nil {
        return
    }

    guard let openItem = waitForElement(withIdentifier: "openDashboardFromMenu", in: appElement, timeout: timeout) else {
        throw SmokeFailure.dashboardOpenControlMissing
    }
    let error = AXUIElementPerformAction(openItem, kAXPressAction as CFString)
    guard error == .success else {
        throw SmokeFailure.dashboardOpenFailed(error)
    }

    guard waitForElement(withIdentifier: "workspace-dashboard", in: appElement, timeout: timeout) != nil else {
        throw SmokeFailure.workspaceButtonMissing("workspace-dashboard")
    }
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

private func verifyWorkspaceNavigation(
    appElement: AXUIElement,
    identifier: String,
    expectedText: String
) throws {
    guard let button = waitForElement(withIdentifier: identifier, in: appElement, timeout: timeout) else {
        throw SmokeFailure.workspaceButtonMissing(identifier)
    }

    let error = AXUIElementPerformAction(button, kAXPressAction as CFString)
    guard error == .success else {
        throw SmokeFailure.pressFailed(identifier: identifier, error)
    }

    Thread.sleep(forTimeInterval: navigationDelay)

    guard waitForText(expectedText, in: appElement, timeout: timeout) else {
        throw SmokeFailure.expectedTextMissing(expectedText)
    }

    print("ok: \(identifier) -> \(expectedText)")
}

private func verifySettingsTabNavigation(
    appElement: AXUIElement,
    identifier: String,
    expectedText: String
) throws {
    guard let button = waitForElement(withIdentifier: identifier, in: appElement, timeout: timeout) else {
        throw SmokeFailure.settingsTabMissing(identifier)
    }

    let error = AXUIElementPerformAction(button, kAXPressAction as CFString)
    guard error == .success else {
        throw SmokeFailure.pressFailed(identifier: identifier, error)
    }

    Thread.sleep(forTimeInterval: navigationDelay)

    guard waitForText(expectedText, in: appElement, timeout: timeout) else {
        throw SmokeFailure.expectedTextMissing(expectedText)
    }

    guard waitForSelectedValue(identifier: identifier, in: appElement, timeout: timeout) else {
        throw SmokeFailure.selectedValueMissing(identifier)
    }

    print("ok: \(identifier) -> \(expectedText)")
}

private func waitForElement(
    withIdentifier identifier: String,
    in root: AXUIElement,
    timeout: TimeInterval
) -> AXUIElement? {
    let deadline = Date().addingTimeInterval(timeout)
    repeat {
        if let element = findElement(in: root, maxDepth: 32, maxNodes: 35_000, where: {
            identifierMatches(stringAttribute($0, "AXIdentifier" as CFString), expected: identifier)
        }) {
            return element
        }
        Thread.sleep(forTimeInterval: 0.1)
    } while Date() < deadline
    return nil
}

private func identifierMatches(_ actual: String?, expected: String) -> Bool {
    actual == expected || actual == "\(expected):"
}

private func waitForText(
    _ text: String,
    in root: AXUIElement,
    timeout: TimeInterval
) -> Bool {
    let deadline = Date().addingTimeInterval(timeout)
    repeat {
        if findElement(in: root, maxDepth: 32, maxNodes: 35_000, where: { element in
            textAttributes(of: element).contains { $0.localizedCaseInsensitiveContains(text) }
        }) != nil {
            return true
        }
        Thread.sleep(forTimeInterval: 0.1)
    } while Date() < deadline
    return false
}

private func waitForSelectedValue(
    identifier: String,
    in root: AXUIElement,
    timeout: TimeInterval
) -> Bool {
    let deadline = Date().addingTimeInterval(timeout)
    repeat {
        if let element = waitForElement(withIdentifier: identifier, in: root, timeout: 0.2),
           textAttributes(of: element).contains(where: { $0.localizedCaseInsensitiveContains("선택됨") }) {
            return true
        }
        Thread.sleep(forTimeInterval: 0.1)
    } while Date() < deadline
    return false
}

private func findElement(
    in root: AXUIElement,
    maxDepth: Int,
    maxNodes: Int,
    where predicate: (AXUIElement) -> Bool
) -> AXUIElement? {
    var stack: [(AXUIElement, Int)] = [(root, 0)]
    var visited = Set<CFHashCode>()
    var visitedCount = 0

    while let (element, depth) = stack.popLast() {
        let elementHash = CFHash(element)
        guard visited.insert(elementHash).inserted else {
            continue
        }

        visitedCount += 1
        guard visitedCount <= maxNodes else {
            return nil
        }

        if predicate(element) {
            return element
        }

        guard depth < maxDepth else {
            continue
        }

        let children = childElements(of: element)
        for child in children.reversed() {
            stack.append((child, depth + 1))
        }
    }

    return nil
}

private func childElements(of element: AXUIElement) -> [AXUIElement] {
    let attributes: [CFString] = [
        kAXWindowsAttribute as CFString,
        kAXChildrenAttribute as CFString,
        "AXVisibleChildren" as CFString,
    ]

    var result: [AXUIElement] = []
    for attribute in attributes {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, attribute, &value) == .success else {
            continue
        }

        if let children = value as? [AXUIElement] {
            result.append(contentsOf: children)
        } else if CFGetTypeID(value) == AXUIElementGetTypeID() {
            result.append(value as! AXUIElement)
        }
    }
    return result
}

private func textAttributes(of element: AXUIElement) -> [String] {
    [
        kAXTitleAttribute as CFString,
        kAXDescriptionAttribute as CFString,
        kAXValueAttribute as CFString,
    ].compactMap { stringAttribute(element, $0) }
}

private func stringAttribute(_ element: AXUIElement, _ attribute: CFString) -> String? {
    var value: CFTypeRef?
    guard AXUIElementCopyAttributeValue(element, attribute, &value) == .success else {
        return nil
    }

    if let string = value as? String {
        return string
    }
    if let attributedString = value as? NSAttributedString {
        return attributedString.string
    }
    if let number = value as? NSNumber {
        return number.stringValue
    }
    return nil
}
