#!/usr/bin/env swift

import AppKit
import ApplicationServices
import Darwin
import Foundation

private enum SmokeFailure: Error, CustomStringConvertible {
    case accessibilityPermissionMissing
    case appLaunchFailed(bundleID: String, appName: String)
    case dashboardOpenFailed
    case expectedControlMissing(String)
    case commandQDidNotTerminate
    case appDidNotReopen

    var description: String {
        switch self {
        case .accessibilityPermissionMissing:
            return "Accessibility permission is not granted for Terminal/Codex."
        case let .appLaunchFailed(bundleID, appName):
            return "KLMS Mac app is not running and could not be launched. Expected bundle id '\(bundleID)' or app name '\(appName)'."
        case .dashboardOpenFailed:
            return "Could not open the KLMS dashboard window before verifying actions."
        case let .expectedControlMissing(label):
            return "Expected Mac action control is missing from the accessibility tree: \(label)."
        case .commandQDidNotTerminate:
            return "Command-Q did not terminate KLMS Sync within the timeout."
        case .appDidNotReopen:
            return "KLMS Sync did not reopen after Command-Q verification."
        }
    }
}

private let environment = ProcessInfo.processInfo.environment
private let bundleID = environment["KLMS_MAC_BUNDLE_ID"] ?? "com.local.KLMSync"
private let appName = environment["KLMS_MAC_APP_NAME"] ?? "KLMS Sync"
private let appPath = ((environment["KLMS_MAC_APP_PATH"] ?? "~/Applications/KLMS Sync.app") as NSString)
    .expandingTildeInPath
private let timeout = TimeInterval(environment["KLMS_MAC_AX_TIMEOUT_SECONDS"] ?? "5.0") ?? 5.0
private let verifyCommandQ = environment["KLMS_MAC_SMOKE_SKIP_CMD_Q"] != "1"
private let requiredDashboardControls = [
    "전체 동기화",
]
private let requiredLogControls = [
    "전체 기록 지우기",
    "실행 로그 지우기",
    "서버 로그 지우기",
]

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

    var app = try ensureAppRunning()
    var appElement = AXUIElementCreateApplication(app.processIdentifier)
    try openDashboardWindow(appElement: appElement)
    try verifyDashboardActions(appElement: appElement)
    try verifyLogActions(appElement: appElement)

    if verifyCommandQ {
        try verifyCommandQTerminatesAndReopens(app: app)
        app = try ensureAppRunning()
        appElement = AXUIElementCreateApplication(app.processIdentifier)
        try openDashboardWindow(appElement: appElement)
    }

    print("ok: KLMS Mac basic app actions are reachable")
}

private func ensureAppRunning() throws -> NSRunningApplication {
    if let app = findRunningApp() {
        return app
    }
    launchApp()
    let deadline = Date().addingTimeInterval(timeout)
    repeat {
        if let app = findRunningApp() {
            return app
        }
        Thread.sleep(forTimeInterval: 0.1)
    } while Date() < deadline
    throw SmokeFailure.appLaunchFailed(bundleID: bundleID, appName: appName)
}

private func findRunningApp() -> NSRunningApplication? {
    let runningByBundleID = NSRunningApplication.runningApplications(withBundleIdentifier: bundleID)
    let runningByName = NSWorkspace.shared.runningApplications.filter { app in
        app.localizedName == appName || app.executableURL?.lastPathComponent == "KLMSMac"
    }
    return (runningByBundleID + runningByName).first(where: { !$0.isTerminated })
}

private func launchApp() {
    if runOpen(arguments: ["-b", bundleID]) {
        return
    }
    if runOpen(arguments: ["-a", appName]) {
        return
    }
    _ = runOpen(arguments: [appPath])
}

private func runOpen(arguments: [String]) -> Bool {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/usr/bin/open")
    process.arguments = arguments
    process.standardOutput = Pipe()
    process.standardError = Pipe()
    try? process.run()
    process.waitUntilExit()
    return process.terminationStatus == 0
}

private func openDashboardWindow(appElement: AXUIElement) throws {
    requestDashboardWindowReopen()
    guard waitForElement(withIdentifier: "workspace-dashboard", in: appElement, timeout: timeout) != nil else {
        throw SmokeFailure.dashboardOpenFailed
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

private func verifyDashboardActions(appElement: AXUIElement) throws {
    try pressWorkspaceButton("workspace-dashboard", appElement: appElement)
    for label in requiredDashboardControls {
        guard waitForText(label, in: appElement, timeout: timeout) else {
            throw SmokeFailure.expectedControlMissing(label)
        }
    }
    print("ok: dashboard action controls")
}

private func verifyLogActions(appElement: AXUIElement) throws {
    try pressWorkspaceButton("workspace-activityLogs", appElement: appElement)
    for label in requiredLogControls {
        guard waitForText(label, in: appElement, timeout: timeout) else {
            throw SmokeFailure.expectedControlMissing(label)
        }
    }
    print("ok: log action controls")
}

private func pressWorkspaceButton(_ identifier: String, appElement: AXUIElement) throws {
    guard let button = waitForElement(withIdentifier: identifier, in: appElement, timeout: timeout) else {
        throw SmokeFailure.expectedControlMissing(identifier)
    }
    _ = AXUIElementPerformAction(button, kAXPressAction as CFString)
    if let contentIdentifier = workspaceContentIdentifier(for: identifier) {
        _ = waitForElement(withIdentifier: contentIdentifier, in: appElement, timeout: timeout)
    } else {
        Thread.sleep(forTimeInterval: 0.1)
    }
}

private func workspaceContentIdentifier(for buttonIdentifier: String) -> String? {
    let prefix = "workspace-"
    guard buttonIdentifier.hasPrefix(prefix) else {
        return nil
    }
    return "workspace-content-\(buttonIdentifier.dropFirst(prefix.count))"
}

private func verifyCommandQTerminatesAndReopens(app: NSRunningApplication) throws {
    sendCommandQ()

    let deadline = Date().addingTimeInterval(timeout)
    repeat {
        if app.isTerminated || !isProcessAlive(app.processIdentifier) {
            print("ok: Command-Q terminates KLMS Sync")
            launchApp()
            let reopenDeadline = Date().addingTimeInterval(timeout)
            repeat {
                if findRunningApp() != nil {
                    print("ok: KLMS Sync reopens after Command-Q")
                    return
                }
                Thread.sleep(forTimeInterval: 0.1)
            } while Date() < reopenDeadline
            throw SmokeFailure.appDidNotReopen
        }
        Thread.sleep(forTimeInterval: 0.1)
    } while Date() < deadline

    throw SmokeFailure.commandQDidNotTerminate
}

private func isProcessAlive(_ pid: pid_t) -> Bool {
    kill(pid, 0) == 0 || errno == EPERM
}

private func sendCommandQ() {
    let escapedAppName = appName.replacingOccurrences(of: "\"", with: "\\\"")
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
    process.arguments = [
        "-e", "tell application \"\(escapedAppName)\" to activate",
        "-e", "repeat 20 times",
        "-e", "tell application \"System Events\" to set frontName to name of first application process whose frontmost is true",
        "-e", "if frontName is \"KLMSMac\" then exit repeat",
        "-e", "delay 0.1",
        "-e", "end repeat",
        "-e", "tell application \"System Events\" to keystroke \"q\" using command down",
    ]
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
    let deadline = Date().addingTimeInterval(timeout)
    repeat {
        if let element = findElement(in: root, maxDepth: 32, maxNodes: 35_000, where: {
            identifierMatches(stringAttribute($0, "AXIdentifier" as CFString), expected: identifier)
        }) {
            return element
        }
        Thread.sleep(forTimeInterval: 0.05)
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
        Thread.sleep(forTimeInterval: 0.05)
    } while Date() < deadline
    return false
}

private func identifierMatches(_ actual: String?, expected: String) -> Bool {
    actual == expected || actual == "\(expected):"
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

private func textAttributes(of element: AXUIElement) -> [String] {
    [
        kAXTitleAttribute as CFString,
        kAXDescriptionAttribute as CFString,
        kAXValueAttribute as CFString,
        "AXHelp" as CFString,
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
