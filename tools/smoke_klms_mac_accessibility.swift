#!/usr/bin/env swift

import AppKit
import ApplicationServices
import Foundation

private enum SmokeFailure: Error, CustomStringConvertible {
    case accessibilityPermissionMissing
    case appNotRunning(bundleID: String, appName: String)
    case accessibilityTreeUnavailable(frontmostApp: String?)
    case dashboardOpenControlMissing
    case dashboardOpenFailed(AXError)
    case workspaceButtonMissing(String)
    case workspaceContentMissing(String)
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
        case let .accessibilityTreeUnavailable(frontmostApp):
            return "KLMS Mac window is visible, but macOS Accessibility is not exposing the app window tree. Frontmost app: \(frontmostApp ?? "unknown"). Unlock the active Mac session, bring KLMS Sync to the front, then rerun the smoke test."
        case .dashboardOpenControlMissing:
            return "Could not find the menu item that opens the KLMS dashboard window."
        case let .dashboardOpenFailed(error):
            return "Could not open the KLMS dashboard window from the menu bar: \(error)."
        case let .workspaceButtonMissing(identifier):
            return "Could not find workspace button with accessibility identifier '\(identifier)'."
        case let .workspaceContentMissing(identifier):
            return "Could not find rendered workspace content with accessibility identifier '\(identifier)'."
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

private struct WorkspaceSmokeTarget {
    var rawValue: String
    var title: String
    var expectedTexts: [String] = []
    var buttonIdentifier: String { "workspace-\(rawValue)" }
    var scrollIdentifier: String { "workspace-scroll-\(rawValue)" }
    var panelIdentifier: String { "workspace-panel-workspace-\(rawValue)" }
    var renderedIdentifier: String { "workspace-rendered-section-\(rawValue)" }
}

private struct SettingsSmokeTarget {
    var rawValue: String
    var expectedText: String
    var identifier: String { "settings-\(rawValue)" }
}

private let workspaceTargets = [
    WorkspaceSmokeTarget(rawValue: "dashboard", title: "대시보드", expectedTexts: ["전체 동기화"]),
    WorkspaceSmokeTarget(rawValue: "files", title: "파일", expectedTexts: ["파일 목록", "필터와 검색"]),
    WorkspaceSmokeTarget(rawValue: "tasks", title: "과제/시험", expectedTexts: ["과제", "시험", "필터와 검색"]),
    WorkspaceSmokeTarget(rawValue: "notices", title: "공지", expectedTexts: ["공지 분류"]),
    WorkspaceSmokeTarget(rawValue: "calendar", title: "캘린더", expectedTexts: ["캘린더 일정", "KLMS 기준 반영"]),
    WorkspaceSmokeTarget(rawValue: "activityLogs", title: "로그", expectedTexts: ["실행 로그 지우기", "서버 로그 지우기"]),
    WorkspaceSmokeTarget(rawValue: "diagnostics", title: "진단", expectedTexts: ["상태 검사", "권한/환경 진단"]),
    WorkspaceSmokeTarget(rawValue: "settings", title: "설정", expectedTexts: ["바로 반영되는 설정"]),
]

private let settingsTargets = [
    SettingsSmokeTarget(rawValue: "app", expectedText: "바로 반영되는 설정"),
    SettingsSmokeTarget(rawValue: "login", expectedText: "KAIST 아이디"),
    SettingsSmokeTarget(rawValue: "sync", expectedText: "Safari 자동화"),
    SettingsSmokeTarget(rawValue: "files", expectedText: "파일 확인"),
    SettingsSmokeTarget(rawValue: "notice", expectedText: "메모 이름"),
]

do {
    try runSmoke()
} catch {
    FileHandle.standardError.write(Data("smoke failed: \(error)\n".utf8))
    FileHandle.standardError.write(Data(visibleWindowDiagnostics().utf8))
    exit(1)
}

private func runSmoke() throws {
    let trustedOptions = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: false] as CFDictionary
    guard AXIsProcessTrustedWithOptions(trustedOptions) else {
        throw SmokeFailure.accessibilityPermissionMissing
    }

    let runningByBundleID = NSRunningApplication.runningApplications(withBundleIdentifier: bundleID)
    let runningByName = NSWorkspace.shared.runningApplications.filter { app in
        app.localizedName == appName || app.executableURL?.lastPathComponent == "KLMSMac"
    }
    guard let app = (runningByBundleID + runningByName).first(where: { !$0.isTerminated }) else {
        throw SmokeFailure.appNotRunning(bundleID: bundleID, appName: appName)
    }

    let appElement = AXUIElementCreateApplication(app.processIdentifier)

    try openDashboardWindowIfNeeded(appElement: appElement)

    for target in workspaceTargets {
        try verifyWorkspaceNavigation(appElement: appElement, target: target)
    }
    for target in settingsTargets {
        try verifySettingsTabNavigation(
            appElement: appElement,
            identifier: target.identifier,
            expectedText: target.expectedText
        )
    }
    try verifyWorkspaceNavigation(appElement: appElement, target: workspaceTargets[0])

    print("ok: KLMS Mac workspace accessibility navigation is responsive")
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
        throw SmokeFailure.accessibilityTreeUnavailable(
            frontmostApp: NSWorkspace.shared.frontmostApplication?.localizedName
        )
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

private func verifyWorkspaceNavigation(
    appElement: AXUIElement,
    target: WorkspaceSmokeTarget
) throws {
    guard let button = waitForElement(withIdentifier: target.buttonIdentifier, in: appElement, timeout: timeout) else {
        throw SmokeFailure.workspaceButtonMissing(target.buttonIdentifier)
    }

    let error = AXUIElementPerformAction(button, kAXPressAction as CFString)
    guard error == .success else {
        throw SmokeFailure.pressFailed(identifier: target.buttonIdentifier, error)
    }

    Thread.sleep(forTimeInterval: navigationDelay)

    for identifier in [target.panelIdentifier, target.renderedIdentifier] {
        guard waitForElement(withIdentifier: identifier, in: appElement, timeout: timeout) != nil else {
            throw SmokeFailure.workspaceContentMissing(identifier)
        }
    }

    for expectedText in target.expectedTexts {
        guard waitForText(expectedText, in: appElement, timeout: timeout) else {
            throw SmokeFailure.expectedTextMissing(expectedText)
        }
    }

    print("ok: \(target.buttonIdentifier) -> \(target.title)")
}

private func verifySettingsTabNavigation(
    appElement: AXUIElement,
    identifier: String,
    expectedText: String
) throws {
    guard waitForElement(withIdentifier: identifier, in: appElement, timeout: timeout) != nil else {
        throw SmokeFailure.settingsTabMissing(identifier)
    }

    var lastError: AXError = .success
    var didSelect = false
    for _ in 0..<5 {
        guard let button = waitForElement(withIdentifier: identifier, in: appElement, timeout: timeout) else {
            throw SmokeFailure.settingsTabMissing(identifier)
        }
        let alreadySelected = textAttributes(of: button).contains { $0.localizedCaseInsensitiveContains("선택됨") }
        if !alreadySelected {
            _ = AXUIElementPerformAction(button, "AXScrollToVisible" as CFString)
            let error = AXUIElementPerformAction(button, kAXPressAction as CFString)
            lastError = error
            if error != .success {
                Thread.sleep(forTimeInterval: 0.25)
                continue
            }
        }

        Thread.sleep(forTimeInterval: navigationDelay)
        didSelect = waitForSelectedValue(identifier: identifier, in: appElement, timeout: 0.7)
        if didSelect, waitForText(expectedText, in: appElement, timeout: timeout) {
            print("ok: \(identifier) -> \(expectedText)")
            return
        }
        Thread.sleep(forTimeInterval: 0.25)
    }

    if lastError != .success {
        throw SmokeFailure.pressFailed(identifier: identifier, lastError)
    }
    if !didSelect {
        throw SmokeFailure.selectedValueMissing(identifier)
    }
    if !waitForText(expectedText, in: appElement, timeout: timeout) {
        throw SmokeFailure.expectedTextMissing(expectedText)
    }
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
        if let rawValue = workspaceRawValue(from: identifier),
           waitForElement(withIdentifier: "workspace-content-\(rawValue)", in: root, timeout: 0.1) != nil {
            return true
        }
        Thread.sleep(forTimeInterval: 0.1)
    } while Date() < deadline
    return false
}

private func workspaceRawValue(from identifier: String) -> String? {
    let prefix = "workspace-"
    guard identifier.hasPrefix(prefix) else {
        return nil
    }
    return String(identifier.dropFirst(prefix.count))
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
