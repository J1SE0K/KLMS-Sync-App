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
    case layoutOverlap(String)
    case screenshotFailed(String)

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
        case let .layoutOverlap(message):
            return message
        case let .screenshotFailed(message):
            return message
        }
    }
}

private let environment = ProcessInfo.processInfo.environment
private let bundleID = environment["KLMS_MAC_BUNDLE_ID"] ?? "com.local.KLMSync"
private let appName = environment["KLMS_MAC_APP_NAME"] ?? "KLMS Sync"
private let navigationDelay = TimeInterval(environment["KLMS_MAC_AX_NAVIGATION_DELAY_SECONDS"] ?? "0.60") ?? 0.60
private let timeout = TimeInterval(environment["KLMS_MAC_AX_TIMEOUT_SECONDS"] ?? "5.0") ?? 5.0
private let screenshotDirectoryURL: URL? = {
    guard let rawPath = environment["KLMS_MAC_AX_SCREENSHOT_DIR"]?.trimmingCharacters(in: .whitespacesAndNewlines),
          !rawPath.isEmpty else {
        return nil
    }
    return URL(fileURLWithPath: (rawPath as NSString).expandingTildeInPath, isDirectory: true)
}()

private struct WorkspaceSmokeTarget {
    var rawValue: String
    var title: String
    var expectedTexts: [String] = []
    var buttonIdentifier: String { "workspace-\(rawValue)" }
    var scrollIdentifier: String { "workspace-scroll-\(rawValue)" }
    var panelIdentifier: String { "workspace-panel-workspace-\(rawValue)" }
    var renderedIdentifier: String { "workspace-container-\(rawValue)" }
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
    FileHandle.standardError.write(Data(sessionDiagnostics().utf8))
    captureFailureScreenshotIfRequested()
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
    bringKLMSAppForward(app: app, appElement: appElement)

    try openDashboardWindowIfNeeded(appElement: appElement)
    try verifyWorkspaceButtonsDoNotOverlap(appElement: appElement)

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
    try verifySettingsTabsDoNotOverlap(appElement: appElement)
    try verifyWorkspaceNavigation(appElement: appElement, target: workspaceTargets[0])

    print("ok: KLMS Mac workspace accessibility navigation is responsive")
}

private func bringKLMSAppForward(app: NSRunningApplication, appElement: AXUIElement) {
    activateApplicationBundle()
    app.unhide()
    app.activate(options: [.activateAllWindows])
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

private func verifyWorkspaceNavigation(
    appElement: AXUIElement,
    target: WorkspaceSmokeTarget
) throws {
    var lastError: AXError = .success
    var didSelect = false
    for _ in 0..<5 {
        guard let button = waitForElement(withIdentifier: target.buttonIdentifier, in: appElement, timeout: timeout) else {
            throw SmokeFailure.workspaceButtonMissing(target.buttonIdentifier)
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

        let requiredIdentifiers = [target.renderedIdentifier]
        guard waitForElements(withIdentifiers: requiredIdentifiers, in: appElement, timeout: timeout) else {
            for identifier in requiredIdentifiers where waitForElement(withIdentifier: identifier, in: appElement, timeout: 0.1) == nil {
                throw SmokeFailure.workspaceContentMissing(identifier)
            }
            throw SmokeFailure.workspaceContentMissing(requiredIdentifiers.joined(separator: ", "))
        }

        Thread.sleep(forTimeInterval: navigationDelay)
        didSelect = waitForSelectedValue(identifier: target.buttonIdentifier, in: appElement, timeout: 0.7)
        guard didSelect else {
            Thread.sleep(forTimeInterval: 0.25)
            continue
        }

        var foundAllExpectedText = true
        for expectedText in target.expectedTexts where !waitForText(expectedText, in: appElement, timeout: timeout) {
            foundAllExpectedText = false
            break
        }
        if foundAllExpectedText {
            try captureScreenshotIfRequested(named: "workspace-\(target.rawValue)")
            print("ok: \(target.buttonIdentifier) -> \(target.title)")
            return
        }

        Thread.sleep(forTimeInterval: 0.25)
    }

    if lastError != .success {
        throw SmokeFailure.pressFailed(identifier: target.buttonIdentifier, lastError)
    }
    if !didSelect {
        throw SmokeFailure.selectedValueMissing(target.buttonIdentifier)
    }
    for expectedText in target.expectedTexts where !waitForText(expectedText, in: appElement, timeout: timeout) {
        throw SmokeFailure.expectedTextMissing(expectedText)
    }
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
            try captureScreenshotIfRequested(named: identifier)
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
    try captureScreenshotIfRequested(named: identifier)
}

private func verifyWorkspaceButtonsDoNotOverlap(appElement: AXUIElement) throws {
    let frames = workspaceTargets.compactMap { target -> (String, CGRect)? in
        guard let element = waitForElement(withIdentifier: target.buttonIdentifier, in: appElement, timeout: timeout),
              let frame = accessibilityFrame(of: element),
              isMeaningful(frame) else {
            return nil
        }
        return (target.buttonIdentifier, frame)
    }
    try verifyNoMeaningfulOverlap(frames, context: "workspace navigation")
}

private func verifySettingsTabsDoNotOverlap(appElement: AXUIElement) throws {
    guard waitForElement(withIdentifier: "settings-app", in: appElement, timeout: 0.2) != nil else {
        return
    }
    let frames = settingsTargets.compactMap { target -> (String, CGRect)? in
        guard let element = waitForElement(withIdentifier: target.identifier, in: appElement, timeout: timeout),
              let frame = accessibilityFrame(of: element),
              isMeaningful(frame) else {
            return nil
        }
        return (target.identifier, frame)
    }
    try verifyNoMeaningfulOverlap(frames, context: "settings tabs")
}

private func verifyNoMeaningfulOverlap(_ frames: [(String, CGRect)], context: String) throws {
    for firstIndex in frames.indices {
        for secondIndex in frames.indices where secondIndex > firstIndex {
            let first = frames[firstIndex]
            let second = frames[secondIndex]
            let intersection = first.1.intersection(second.1)
            guard !intersection.isNull, isMeaningful(intersection) else {
                continue
            }
            let minArea = max(1, min(first.1.width * first.1.height, second.1.width * second.1.height))
            let overlapRatio = (intersection.width * intersection.height) / minArea
            guard overlapRatio > 0.08,
                  intersection.width > 6,
                  intersection.height > 6 else {
                continue
            }
            throw SmokeFailure.layoutOverlap(
                "\(context) layout overlap: \(first.0) and \(second.0) overlap by \(Int((overlapRatio * 100).rounded()))%."
            )
        }
    }
}

private func accessibilityFrame(of element: AXUIElement) -> CGRect? {
    var positionValue: CFTypeRef?
    var sizeValue: CFTypeRef?
    guard AXUIElementCopyAttributeValue(element, kAXPositionAttribute as CFString, &positionValue) == .success,
          AXUIElementCopyAttributeValue(element, kAXSizeAttribute as CFString, &sizeValue) == .success,
          let positionAXValue = positionValue,
          let sizeAXValue = sizeValue else {
        return nil
    }

    var point = CGPoint.zero
    var size = CGSize.zero
    guard CFGetTypeID(positionAXValue) == AXValueGetTypeID(),
          CFGetTypeID(sizeAXValue) == AXValueGetTypeID(),
          AXValueGetValue(positionAXValue as! AXValue, .cgPoint, &point),
          AXValueGetValue(sizeAXValue as! AXValue, .cgSize, &size) else {
        return nil
    }
    return CGRect(origin: point, size: size)
}

private func isMeaningful(_ frame: CGRect) -> Bool {
    frame.width.isFinite
        && frame.height.isFinite
        && frame.width > 1
        && frame.height > 1
}

private func captureScreenshotIfRequested(named rawName: String) throws {
    guard let screenshotDirectoryURL else {
        return
    }
    try FileManager.default.createDirectory(
        at: screenshotDirectoryURL,
        withIntermediateDirectories: true
    )
    guard let windowID = visibleDashboardWindowID() else {
        throw SmokeFailure.screenshotFailed("Could not find a visible KLMS Sync window to capture.")
    }
    let safeName = rawName
        .replacingOccurrences(of: "[^A-Za-z0-9._-]+", with: "-", options: .regularExpression)
        .trimmingCharacters(in: CharacterSet(charactersIn: "-"))
    let outputURL = screenshotDirectoryURL.appendingPathComponent("\(safeName).png")
    let captured = captureWindowUsingScreencapture(windowID: windowID, to: outputURL)
    guard captured,
          FileManager.default.fileExists(atPath: outputURL.path) else {
        throw SmokeFailure.screenshotFailed("Could not capture KLMS Sync screenshot for '\(rawName)'.")
    }
    print("screenshot: \(outputURL.path)")
}

private func captureWindowUsingScreencapture(windowID: Int, to outputURL: URL) -> Bool {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/usr/sbin/screencapture")
    process.arguments = ["-x", "-l", String(windowID), outputURL.path]
    process.standardOutput = Pipe()
    process.standardError = Pipe()
    do {
        try process.run()
        process.waitUntilExit()
        return process.terminationStatus == 0
    } catch {
        return false
    }
}

private func captureFailureScreenshotIfRequested() {
    do {
        try captureScreenshotIfRequested(named: "failure-current-window")
    } catch {
        FileHandle.standardError.write(Data("screenshot failed: \(error)\n".utf8))
    }
}

private func visibleDashboardWindowID() -> Int? {
    let windows = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] ?? []
    let candidates = windows.compactMap { info -> (id: Int, area: Double)? in
        let owner = info[kCGWindowOwnerName as String] as? String ?? ""
        guard owner == appName || owner == "KLMS Sync" || owner == "KLMSMac" else { return nil }
        let layer = info[kCGWindowLayer as String] as? Int ?? -1
        guard layer == 0,
              let id = info[kCGWindowNumber as String] as? Int else {
            return nil
        }
        let bounds = info[kCGWindowBounds as String] as? [String: Any] ?? [:]
        let width = (bounds["Width"] as? NSNumber)?.doubleValue ?? 0
        let height = (bounds["Height"] as? NSNumber)?.doubleValue ?? 0
        return (id, width * height)
    }
    return candidates.max { $0.area < $1.area }?.id
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

private func waitForElements(
    withIdentifiers identifiers: [String],
    in root: AXUIElement,
    timeout: TimeInterval
) -> Bool {
    let deadline = Date().addingTimeInterval(timeout)
    let expected = Set(identifiers)
    repeat {
        if findIdentifiers(expected, in: root, maxDepth: 32, maxNodes: 35_000).isSuperset(of: identifiers) {
            return true
        }
        Thread.sleep(forTimeInterval: 0.02)
    } while Date() < deadline
    return false
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
