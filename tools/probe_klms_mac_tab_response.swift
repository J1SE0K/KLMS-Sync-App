#!/usr/bin/env swift

import AppKit
import ApplicationServices
import Foundation

private enum ProbeFailure: Error, CustomStringConvertible {
    case accessibilityPermissionMissing
    case appNotRunning(bundleID: String, appName: String)
    case accessibilityTreeUnavailable(frontmostApp: String?)
    case dashboardOpenControlMissing
    case dashboardOpenFailed(AXError)
    case workspaceButtonMissing(String)
    case workspaceSelectionMissing(String)
    case workspaceContentMissing(String)
    case pressFailed(identifier: String, AXError)
    case performanceLimitExceeded(String)

    var description: String {
        switch self {
        case .accessibilityPermissionMissing:
            return "Accessibility permission is not granted for Terminal/Codex. Enable it in System Settings > Privacy & Security > Accessibility."
        case let .appNotRunning(bundleID, appName):
            return "KLMS Mac app is not running. Expected bundle id '\(bundleID)' or app name '\(appName)'."
        case let .accessibilityTreeUnavailable(frontmostApp):
            return "KLMS Mac window is visible, but macOS Accessibility is not exposing the app window tree. Frontmost app: \(frontmostApp ?? "unknown"). Unlock the active Mac session, bring KLMS Sync to the front, then rerun the probe."
        case .dashboardOpenControlMissing:
            return "Could not find the menu item that opens the KLMS dashboard window."
        case let .dashboardOpenFailed(error):
            return "Could not open the KLMS dashboard window from the menu bar: \(error)."
        case let .workspaceButtonMissing(identifier):
            return "Could not find workspace button with accessibility identifier '\(identifier)'."
        case let .workspaceSelectionMissing(identifier):
            return "Workspace button '\(identifier)' did not report the selected state."
        case let .workspaceContentMissing(identifier):
            return "Workspace content marker '\(identifier)' did not appear after selection."
        case let .pressFailed(identifier, error):
            return "Could not press button '\(identifier)': \(error)."
        case let .performanceLimitExceeded(message):
            return message
        }
    }
}

private struct ProbeTarget {
    var rawValue: String
    var buttonIdentifier: String { "workspace-\(rawValue)" }
    var selectionIdentifier: String { "workspace-container-\(rawValue)" }
    var contentIdentifier: String { "workspace-panel-workspace-\(rawValue)" }
}

private let environment = ProcessInfo.processInfo.environment
private let bundleID = environment["KLMS_MAC_BUNDLE_ID"] ?? "com.local.KLMSync"
private let appName = environment["KLMS_MAC_APP_NAME"] ?? "KLMS Sync"
private let timeout = TimeInterval(environment["KLMS_MAC_AX_TIMEOUT_SECONDS"] ?? "5.0") ?? 5.0
private let runCount = max(1, Int(environment["KLMS_MAC_TAB_PROBE_RUNS"] ?? "1") ?? 1)
private let averageLimit = Double(environment["KLMS_MAC_TAB_AVERAGE_LIMIT_MS"] ?? "") ?? 0
private let slowestLimit = Double(environment["KLMS_MAC_TAB_SLOWEST_LIMIT_MS"] ?? "") ?? 0
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
    let message = "probe failed: \(error)\n\(visibleWindowDiagnostics())\(sessionDiagnostics())"
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
    bringKLMSAppForward(app: app, appElement: appElement)
    try openDashboardWindowIfNeeded(appElement: appElement)

    var results: [ProbeRunResult] = []
    for runIndex in 1...runCount {
        if runCount > 1 {
            print("== probe \(runIndex)/\(runCount) ==")
        }
        results.append(try runSingleProbe(appElement: appElement))
    }

    if runCount > 1 {
        let seriesAverage = results.map(\.average).reduce(0, +) / Double(results.count)
        let worstAverage = results.map(\.average).max() ?? 0
        let slowest = results.compactMap(\.slowest).max { $0.1 < $1.1 }
        print("series_average=\(Int(seriesAverage.rounded()))ms worst_run_average=\(Int(worstAverage.rounded()))ms series_slowest=\(slowest?.0 ?? "-"):\(Int((slowest?.1 ?? 0).rounded()))ms")
    }

    if averageLimit > 0,
       let overLimit = results.enumerated().first(where: { $0.element.average > averageLimit }) {
        throw ProbeFailure.performanceLimitExceeded(
            "Probe \(overLimit.offset + 1) average \(Int(overLimit.element.average.rounded()))ms exceeded \(Int(averageLimit.rounded()))ms."
        )
    }
    if slowestLimit > 0,
       let slowest = results.compactMap(\.slowest).max(by: { $0.1 < $1.1 }),
       slowest.1 > slowestLimit {
        throw ProbeFailure.performanceLimitExceeded(
            "Slowest tab \(slowest.0) \(Int(slowest.1.rounded()))ms exceeded \(Int(slowestLimit.rounded()))ms."
        )
    }
}

private func bringKLMSAppForward(app: NSRunningApplication, appElement: AXUIElement) {
    activateApplicationBundle()
    app.unhide()
    app.activate(options: [.activateIgnoringOtherApps, .activateAllWindows])
    AXUIElementSetAttributeValue(appElement, kAXFrontmostAttribute as CFString, kCFBooleanTrue)
    activateApplicationWithAppleScript()
    requestDashboardWindowReopen()

    let deadline = Date().addingTimeInterval(min(1.5, timeout))
    repeat {
        if hasUsableAccessibilityWindow(in: appElement)
            || NSWorkspace.shared.frontmostApplication?.processIdentifier == app.processIdentifier {
            return
        }
        Thread.sleep(forTimeInterval: 0.05)
    } while Date() < deadline
}

private func activateApplicationBundle() {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/usr/bin/open")
    process.arguments = ["-b", bundleID]
    process.standardOutput = Pipe()
    process.standardError = Pipe()
    try? process.run()
    process.waitUntilExit()
}

private func activateApplicationWithAppleScript() {
    let escapedAppName = appName.replacingOccurrences(of: "\"", with: "\\\"")
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
    process.arguments = ["-e", "tell application \"\(escapedAppName)\" to activate"]
    process.standardOutput = Pipe()
    process.standardError = Pipe()
    try? process.run()
    process.waitUntilExit()
}

private struct ProbeRunResult {
    var samples: [(String, Double)]

    var average: Double {
        samples.map(\.1).reduce(0, +) / Double(max(samples.count, 1))
    }

    var slowest: (String, Double)? {
        samples.max { $0.1 < $1.1 }
    }
}

@discardableResult
private func runSingleProbe(appElement: AXUIElement) throws -> ProbeRunResult {
    var samples: [(String, Double)] = []
    for target in targets {
        let elapsed = try measure(target: target, appElement: appElement)
        samples.append((target.rawValue, elapsed))
        print("\(target.rawValue)=\(Int(elapsed.rounded()))ms")
    }

    let result = ProbeRunResult(samples: samples)
    let average = result.average
    let slowest = result.slowest
    print("average=\(Int(average.rounded()))ms slowest=\(slowest?.0 ?? "-"):\(Int((slowest?.1 ?? 0).rounded()))ms")
    return result
}

private func openDashboardWindowIfNeeded(appElement: AXUIElement) throws {
    if waitForElement(withIdentifier: "workspace-dashboard", in: appElement, timeout: 0.4) != nil {
        return
    }

    requestDashboardWindowReopen()
    if waitForElement(withIdentifier: "workspace-dashboard", in: appElement, timeout: timeout) != nil {
        return
    }

    if hasVisibleDashboardWindow(), !hasUsableAccessibilityWindow(in: appElement) {
        throw ProbeFailure.accessibilityTreeUnavailable(
            frontmostApp: NSWorkspace.shared.frontmostApplication?.localizedName
        )
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

private func hasVisibleDashboardWindow() -> Bool {
    let windows = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] ?? []
    return windows.contains { info in
        let owner = info[kCGWindowOwnerName as String] as? String ?? ""
        return owner == appName || owner == "KLMS Sync" || owner == "KLMSMac"
    }
}

private func hasUsableAccessibilityWindow(in appElement: AXUIElement) -> Bool {
    var value: CFTypeRef?
    guard AXUIElementCopyAttributeValue(appElement, kAXWindowsAttribute as CFString, &value) == .success,
          let windows = value as? [AXUIElement] else {
        return false
    }
    return windows.contains { stringAttribute($0, kAXRoleAttribute as CFString) == kAXWindowRole }
}

private func visibleWindowDiagnostics() -> String {
    let windows = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] ?? []
    let matching = windows.compactMap { info -> String? in
        let owner = info[kCGWindowOwnerName as String] as? String ?? ""
        guard owner == appName || owner == "KLMS Sync" || owner == "KLMSMac" else { return nil }
        let title = info[kCGWindowName as String] as? String ?? "-"
        let layer = info[kCGWindowLayer as String] as? Int ?? -1
        let bounds = info[kCGWindowBounds as String] as? [String: Any] ?? [:]
        let width = bounds["Width"] ?? "-"
        let height = bounds["Height"] ?? "-"
        return "visible-window owner=\(owner) title=\(title) layer=\(layer) size=\(width)x\(height)"
    }
    if matching.isEmpty {
        return "visible-window none for \(appName)\n"
    }
    return matching.joined(separator: "\n") + "\n"
}

private func sessionDiagnostics() -> String {
    var lines: [String] = []
    if let session = CGSessionCopyCurrentDictionary() as? [String: Any] {
        let onConsole = diagnosticValue(session["kCGSessionOnConsoleKey"])
        let loginDone = diagnosticValue(session["kCGSessionLoginDoneKey"])
        let screenLocked = diagnosticValue(session["CGSSessionScreenIsLocked"])
        lines.append("session on-console=\(onConsole) login-done=\(loginDone) screen-locked=\(screenLocked)")
    } else {
        lines.append("session unavailable")
    }
    if let frontmost = NSWorkspace.shared.frontmostApplication {
        lines.append(
            "frontmost-app name=\(frontmost.localizedName ?? "-") pid=\(frontmost.processIdentifier) bundle=\(frontmost.bundleIdentifier ?? "-")"
        )
    } else {
        lines.append("frontmost-app unavailable")
    }
    return lines.joined(separator: "\n") + "\n"
}

private func diagnosticValue(_ value: Any?) -> String {
    switch value {
    case let number as NSNumber:
        return number.boolValue ? "true" : "false"
    case let string as String where !string.isEmpty:
        return string
    case .some:
        return "present"
    case .none:
        return "unknown"
    }
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

    let requiredIdentifiers = [target.selectionIdentifier, target.contentIdentifier]
    guard waitForElements(withIdentifiers: requiredIdentifiers, in: appElement, timeout: timeout) else {
        if waitForElement(withIdentifier: target.selectionIdentifier, in: appElement, timeout: 0.1) == nil {
            throw ProbeFailure.workspaceSelectionMissing(target.buttonIdentifier)
        }
        throw ProbeFailure.workspaceContentMissing(target.contentIdentifier)
    }
    let end = DispatchTime.now()
    return Double(end.uptimeNanoseconds - start.uptimeNanoseconds) / 1_000_000
}

private func waitForElements(
    withIdentifiers identifiers: [String],
    in root: AXUIElement,
    timeout: TimeInterval
) -> Bool {
    let deadline = Date().addingTimeInterval(timeout)
    repeat {
        if findIdentifiers(Set(identifiers), in: root, maxDepth: 32, maxNodes: 35_000).isSuperset(of: identifiers) {
            return true
        }
        Thread.sleep(forTimeInterval: 0.02)
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

private func findIdentifiers(
    _ identifiers: Set<String>,
    in root: AXUIElement,
    maxDepth: Int,
    maxNodes: Int
) -> Set<String> {
    var remaining = identifiers
    var found = Set<String>()
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
            return found
        }

        if let identifier = stringAttribute(element, "AXIdentifier" as CFString),
           let match = remaining.first(where: { identifierMatches(identifier, expected: $0) }) {
            found.insert(match)
            remaining.remove(match)
            if remaining.isEmpty {
                return found
            }
        }

        guard depth < maxDepth else {
            continue
        }

        for child in childElements(of: element).reversed() {
            stack.append((child, depth + 1))
        }
    }
    return found
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
