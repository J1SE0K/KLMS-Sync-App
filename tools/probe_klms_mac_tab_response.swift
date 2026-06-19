#!/usr/bin/env swift

import AppKit
import ApplicationServices
import Foundation

private enum ProbeFailure: Error, CustomStringConvertible {
    case accessibilityPermissionMissing
    case appNotRunning(bundleID: String, appName: String)
    case dashboardOpenControlMissing
    case dashboardOpenFailed(AXError)
    case workspaceButtonMissing(String)
    case workspaceSelectionMissing(String)
    case pressFailed(identifier: String, AXError)

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
        case let .workspaceSelectionMissing(identifier):
            return "Workspace button '\(identifier)' did not report the selected state."
        case let .pressFailed(identifier, error):
            return "Could not press button '\(identifier)': \(error)."
        }
    }
}

private struct ProbeTarget {
    var rawValue: String
    var buttonIdentifier: String { "workspace-\(rawValue)" }
}

private let environment = ProcessInfo.processInfo.environment
private let bundleID = environment["KLMS_MAC_BUNDLE_ID"] ?? "com.local.KLMSync"
private let appName = environment["KLMS_MAC_APP_NAME"] ?? "KLMS Sync"
private let timeout = TimeInterval(environment["KLMS_MAC_AX_TIMEOUT_SECONDS"] ?? "5.0") ?? 5.0
private let targets = [
    ProbeTarget(rawValue: "dashboard"),
    ProbeTarget(rawValue: "files"),
    ProbeTarget(rawValue: "tasks"),
    ProbeTarget(rawValue: "notices"),
    ProbeTarget(rawValue: "calendar"),
    ProbeTarget(rawValue: "activityLogs"),
    ProbeTarget(rawValue: "diagnostics"),
    ProbeTarget(rawValue: "settings"),
]

do {
    try runProbe()
} catch {
    let message = "probe failed: \(error)\n"
    FileHandle.standardError.write(Data(message.utf8))
    exit(1)
}

private func runProbe() throws {
    let trustedOptions = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: false] as CFDictionary
    guard AXIsProcessTrustedWithOptions(trustedOptions) else {
        throw ProbeFailure.accessibilityPermissionMissing
    }

    let runningByBundleID = NSRunningApplication.runningApplications(withBundleIdentifier: bundleID)
    let runningByName = NSWorkspace.shared.runningApplications.filter { app in
        app.localizedName == appName || app.executableURL?.lastPathComponent == "KLMSMac"
    }
    guard let app = (runningByBundleID + runningByName).first(where: { !$0.isTerminated }) else {
        throw ProbeFailure.appNotRunning(bundleID: bundleID, appName: appName)
    }

    let appElement = AXUIElementCreateApplication(app.processIdentifier)
    try openDashboardWindowIfNeeded(appElement: appElement)

    var samples: [(String, Double)] = []
    for target in targets {
        let elapsed = try measure(target: target, appElement: appElement)
        samples.append((target.rawValue, elapsed))
        print("\(target.rawValue)=\(Int(elapsed.rounded()))ms")
    }

    let average = samples.map(\.1).reduce(0, +) / Double(max(samples.count, 1))
    let slowest = samples.max { $0.1 < $1.1 }
    print("average=\(Int(average.rounded()))ms slowest=\(slowest?.0 ?? "-"):\(Int((slowest?.1 ?? 0).rounded()))ms")
}

private func openDashboardWindowIfNeeded(appElement: AXUIElement) throws {
    if waitForElement(withIdentifier: "workspace-dashboard", in: appElement, timeout: 0.4) != nil {
        return
    }

    requestDashboardWindowReopen()
    if waitForElement(withIdentifier: "workspace-dashboard", in: appElement, timeout: timeout) != nil {
        return
    }

    guard let openItem = waitForElement(withIdentifier: "openDashboardFromMenu", in: appElement, timeout: timeout) else {
        throw ProbeFailure.dashboardOpenControlMissing
    }
    let error = AXUIElementPerformAction(openItem, kAXPressAction as CFString)
    guard error == .success else {
        throw ProbeFailure.dashboardOpenFailed(error)
    }

    guard waitForElement(withIdentifier: "workspace-dashboard", in: appElement, timeout: timeout) != nil else {
        throw ProbeFailure.workspaceButtonMissing("workspace-dashboard")
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

private func measure(target: ProbeTarget, appElement: AXUIElement) throws -> Double {
    guard let button = waitForElement(withIdentifier: target.buttonIdentifier, in: appElement, timeout: timeout) else {
        throw ProbeFailure.workspaceButtonMissing(target.buttonIdentifier)
    }

    let start = DispatchTime.now()
    let error = AXUIElementPerformAction(button, kAXPressAction as CFString)
    guard error == .success else {
        throw ProbeFailure.pressFailed(identifier: target.buttonIdentifier, error)
    }

    guard waitForSelectedValue(on: button, timeout: timeout) else {
        throw ProbeFailure.workspaceSelectionMissing(target.buttonIdentifier)
    }
    let end = DispatchTime.now()
    return Double(end.uptimeNanoseconds - start.uptimeNanoseconds) / 1_000_000
}

private func waitForSelectedValue(on element: AXUIElement, timeout: TimeInterval) -> Bool {
    let deadline = Date().addingTimeInterval(timeout)
    repeat {
        if textAttributes(of: element).contains(where: { $0.localizedCaseInsensitiveContains("선택됨") }) {
            return true
        }
        Thread.sleep(forTimeInterval: 0.01)
    } while Date() < deadline
    return false
}

private func waitForElement(
    withIdentifier identifier: String,
    in root: AXUIElement,
    timeout: TimeInterval
) -> AXUIElement? {
    let deadline = Date().addingTimeInterval(timeout)
    repeat {
        if let element = findElement(in: root, maxDepth: 32, maxNodes: 35_000, predicate: {
            identifierMatches(stringAttribute($0, "AXIdentifier" as CFString), expected: identifier)
        }) {
            return element
        }
        Thread.sleep(forTimeInterval: 0.02)
    } while Date() < deadline
    return nil
}

private func findElement(
    in root: AXUIElement,
    maxDepth: Int,
    maxNodes: Int,
    predicate: (AXUIElement) -> Bool
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

        for child in childElements(of: element).reversed() {
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

private func stringAttribute(_ element: AXUIElement, _ attribute: CFString) -> String? {
    var value: CFTypeRef?
    guard AXUIElementCopyAttributeValue(element, attribute, &value) == .success else {
        return nil
    }
    return value as? String
}

private func textAttributes(of element: AXUIElement) -> [String] {
    [
        stringAttribute(element, kAXTitleAttribute as CFString),
        stringAttribute(element, kAXDescriptionAttribute as CFString),
        stringAttribute(element, kAXValueAttribute as CFString),
        stringAttribute(element, "AXHelp" as CFString),
    ].compactMap { $0 }
}

private func identifierMatches(_ value: String?, expected: String) -> Bool {
    value == expected || value == "\(expected):"
}
