#!/usr/bin/env swift

import AppKit
import ApplicationServices
import Foundation

private enum SmokeFailure: Error, CustomStringConvertible {
    case accessibilityPermissionMissing
    case appNotRunning(bundleID: String, appName: String)
    case workspaceButtonMissing(String)
    case pressFailed(identifier: String, AXError)
    case expectedTextMissing(String)

    var description: String {
        switch self {
        case .accessibilityPermissionMissing:
            return "Accessibility permission is not granted for Terminal/Codex. Enable it in System Settings > Privacy & Security > Accessibility."
        case let .appNotRunning(bundleID, appName):
            return "KLMS Mac app is not running. Expected bundle id '\(bundleID)' or app name '\(appName)'."
        case let .workspaceButtonMissing(identifier):
            return "Could not find workspace button with accessibility identifier '\(identifier)'."
        case let .pressFailed(identifier, error):
            return "Could not press workspace button '\(identifier)': \(error)."
        case let .expectedTextMissing(text):
            return "Expected text '\(text)' did not appear after navigation."
        }
    }
}

private let environment = ProcessInfo.processInfo.environment
private let bundleID = environment["KLMS_MAC_BUNDLE_ID"] ?? "com.local.KLMSync"
private let appName = environment["KLMS_MAC_APP_NAME"] ?? "KLMS Sync"
private let navigationDelay = TimeInterval(environment["KLMS_MAC_AX_NAVIGATION_DELAY_SECONDS"] ?? "0.35") ?? 0.35
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

_ = app.activate(options: [])
let appElement = AXUIElementCreateApplication(app.processIdentifier)

try verifyWorkspaceNavigation(
    appElement: appElement,
    identifier: "workspace-settings",
    expectedText: "화면/앱"
)
try verifyWorkspaceNavigation(
    appElement: appElement,
    identifier: "workspace-dashboard",
    expectedText: "대시보드"
)

print("ok: KLMS Mac workspace accessibility navigation is responsive")

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

private func waitForElement(
    withIdentifier identifier: String,
    in root: AXUIElement,
    timeout: TimeInterval
) -> AXUIElement? {
    let deadline = Date().addingTimeInterval(timeout)
    repeat {
        if let element = findElement(in: root, maxDepth: 32, maxNodes: 35_000, where: {
            stringAttribute($0, "AXIdentifier" as CFString) == identifier
        }) {
            return element
        }
        Thread.sleep(forTimeInterval: 0.1)
    } while Date() < deadline
    return nil
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

private func findElement(
    in root: AXUIElement,
    maxDepth: Int,
    maxNodes: Int,
    where predicate: (AXUIElement) -> Bool
) -> AXUIElement? {
    var stack: [(AXUIElement, Int)] = [(root, 0)]
    var visitedCount = 0

    while let (element, depth) = stack.popLast() {
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
