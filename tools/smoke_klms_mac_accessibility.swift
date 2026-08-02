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
private let appPath = environment["KLMS_MAC_APP_PATH"]?.trimmingCharacters(in: .whitespacesAndNewlines)
private let navigationDelay = TimeInterval(environment["KLMS_MAC_AX_NAVIGATION_DELAY_SECONDS"] ?? "0.60") ?? 0.60
private let timeout = TimeInterval(environment["KLMS_MAC_AX_TIMEOUT_SECONDS"] ?? "5.0") ?? 5.0
private let verifiesAdaptiveResize = environment["KLMS_MAC_AX_VERIFY_ADAPTIVE_RESIZE"] == "1"
private let primarySyncActionIdentifier = "command-fullSync-primary"
private let screenshotDirectoryURL: URL? = {
    guard let rawPath = environment["KLMS_MAC_AX_SCREENSHOT_DIR"]?.trimmingCharacters(in: .whitespacesAndNewlines),
          !rawPath.isEmpty else {
        return nil
    }
    return URL(fileURLWithPath: (rawPath as NSString).expandingTildeInPath, isDirectory: true)
}()
private var targetProcessIdentifier: pid_t?

private struct WorkspaceSmokeTarget {
    var rawValue: String
    var title: String
    var expectedTexts: [String] = []
    var buttonIdentifier: String { "workspace-\(rawValue)" }
    var scrollIdentifier: String { "workspace-scroll-\(rawValue)" }
    var contentRootIdentifier: String { "workspace-content-root-\(rawValue)" }
    var panelIdentifier: String { "workspace-panel-workspace-\(rawValue)" }
    var renderedIdentifier: String { contentRootIdentifier }
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
    WorkspaceSmokeTarget(rawValue: "settings", title: "설정", expectedTexts: ["이 기기에 바로 적용"]),
]

private let settingsTargets = [
    SettingsSmokeTarget(rawValue: "app", expectedText: "이 기기에 바로 적용"),
    SettingsSmokeTarget(rawValue: "login", expectedText: "KAIST 아이디"),
    SettingsSmokeTarget(rawValue: "sync", expectedText: "Safari 자동화"),
    SettingsSmokeTarget(rawValue: "files", expectedText: "파일 확인"),
    SettingsSmokeTarget(rawValue: "notice", expectedText: "메모 이름"),
]

do {
    try runSmokeWithFocusRecovery()
} catch {
    FileHandle.standardError.write(Data("smoke failed: \(error)\n".utf8))
    FileHandle.standardError.write(Data(accessibilityIdentifierDiagnostics().utf8))
    FileHandle.standardError.write(Data(visibleWindowDiagnostics().utf8))
    FileHandle.standardError.write(Data(sessionDiagnostics().utf8))
    captureFailureScreenshotIfRequested()
    exit(1)
}

private func runSmokeWithFocusRecovery() throws {
    var lastError: Error?
    for attempt in 0..<3 {
        do {
            try runSmoke()
            return
        } catch {
            lastError = error
        }

        guard let recoveryError = lastError else {
            throw SmokeFailure.accessibilityTreeUnavailable(frontmostApp: nil)
        }
        guard let targetProcessIdentifier,
              let app = NSRunningApplication(processIdentifier: targetProcessIdentifier),
              !app.isTerminated else {
            throw recoveryError
        }
        let appElement = AXUIElementCreateApplication(targetProcessIdentifier)
        let isFrontmost = NSWorkspace.shared.frontmostApplication?.processIdentifier == targetProcessIdentifier
        let hasVisibleWindow = hasVisibleDashboardWindow()
        let hasUsableWindow = hasUsableAccessibilityWindow(in: appElement)
        let hasWorkspaceTree = hasMeaningfulWorkspaceAccessibilityTree(in: appElement)
        let needsRecovery = !isFrontmost || !hasVisibleWindow || !hasUsableWindow || !hasWorkspaceTree
        guard needsRecovery else {
            throw recoveryError
        }
        let notice = "smoke notice: transient focus/window loss during attempt \(attempt + 1): "
            + "\(recoveryError). Restoring KLMS Sync before retry "
            + "(frontmost=\(isFrontmost), visible=\(hasVisibleWindow), "
            + "axWindow=\(hasUsableWindow), workspaceTree=\(hasWorkspaceTree)).\n"
        FileHandle.standardError.write(
            Data(notice.utf8)
        )
        bringKLMSAppForward(app: app, appElement: appElement)
    }
    guard let lastError else {
        throw SmokeFailure.accessibilityTreeUnavailable(frontmostApp: nil)
    }
    throw lastError
}

private func accessibilityIdentifierDiagnostics() -> String {
    guard let targetProcessIdentifier else {
        return "accessibility identifiers unavailable: target pid missing\n"
    }
    let root = AXUIElementCreateApplication(targetProcessIdentifier)
    var stack: [(AXUIElement, Int)] = [(root, 0)]
    var visited = Set<AXUIElement>()
    var identifiers = Set<String>()
    var visitedCount = 0

    while let (element, depth) = stack.popLast(), visitedCount < 35_000 {
        guard visited.insert(element).inserted else { continue }
        visitedCount += 1
        if let identifier = stringAttribute(element, "AXIdentifier" as CFString),
           !identifier.isEmpty {
            identifiers.insert(identifier)
        }
        guard depth < 32 else { continue }
        for child in childElements(of: element).reversed() {
            stack.append((child, depth + 1))
        }
    }

    let relevant = identifiers
        .filter {
            $0.contains("workspace")
                || $0.contains("dashboard")
                || $0.contains("command")
                || $0.contains("settings")
        }
        .sorted()
    if relevant.isEmpty {
        return "accessibility identifiers: none matched workspace/dashboard/command/settings (visited \(visitedCount))\n"
    }
    return "accessibility identifiers (visited \(visitedCount)):\n"
        + relevant.prefix(200).map { "  \($0)" }.joined(separator: "\n")
        + "\n"
}

private func runSmoke() throws {
    let trustedOptions = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: false] as CFDictionary
    guard AXIsProcessTrustedWithOptions(trustedOptions) else {
        throw SmokeFailure.accessibilityPermissionMissing
    }

    guard let app = launchKLMSApplicationIfNeeded() else {
        throw SmokeFailure.appNotRunning(bundleID: bundleID, appName: appName)
    }
    targetProcessIdentifier = app.processIdentifier

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
    if verifiesAdaptiveResize {
        try verifyAdaptiveResize(appElement: appElement)
    }

    print("ok: KLMS Mac workspace accessibility navigation is responsive")
}

private func runningKLMSApplication() -> NSRunningApplication? {
    if appPath != nil {
        return NSWorkspace.shared.runningApplications.first(where: {
            !$0.isTerminated && matchesConfiguredAppPath($0)
        })
    }
    if let exactBundleMatch = NSRunningApplication.runningApplications(withBundleIdentifier: bundleID)
        .first(where: { !$0.isTerminated }) {
        return exactBundleMatch
    }
    let runningByName = NSWorkspace.shared.runningApplications.filter { app in
        app.localizedName == appName
            || (appPath == nil && app.executableURL?.lastPathComponent == "KLMSMac")
    }
    return runningByName.first(where: { !$0.isTerminated })
}

private func matchesConfiguredAppPath(_ app: NSRunningApplication) -> Bool {
    guard let appPath,
          let executablePath = app.executableURL?.resolvingSymlinksInPath().standardizedFileURL.path else {
        return false
    }
    let bundlePath = URL(fileURLWithPath: appPath)
        .resolvingSymlinksInPath()
        .standardizedFileURL.path
    return executablePath.hasPrefix(bundlePath + "/Contents/MacOS/")
}

private func launchKLMSApplicationIfNeeded() -> NSRunningApplication? {
    if let app = runningKLMSApplication() {
        return app
    }
    activateApplicationBundle()
    let deadline = Date().addingTimeInterval(timeout)
    repeat {
        if let app = runningKLMSApplication() {
            return app
        }
        Thread.sleep(forTimeInterval: 0.10)
    } while Date() < deadline
    return nil
}

private func bringKLMSAppForward(app: NSRunningApplication, appElement: AXUIElement) {
    if appPath == nil {
        activateApplicationBundle()
    }
    app.unhide()
    app.activate(options: [.activateAllWindows])
    AXUIElementSetAttributeValue(appElement, kAXFrontmostAttribute as CFString, kCFBooleanTrue)
    activateApplicationWithAppleScript()
    if !hasVisibleDashboardWindow() || !hasUsableAccessibilityWindow(in: appElement) {
        requestDashboardWindowReopen()
    }

    let deadline = Date().addingTimeInterval(timeout)
    var stableSamples = 0
    repeat {
        app.unhide()
        app.activate(options: [.activateAllWindows])
        AXUIElementSetAttributeValue(appElement, kAXFrontmostAttribute as CFString, kCFBooleanTrue)
        let isFrontmost = NSWorkspace.shared.frontmostApplication?.processIdentifier == app.processIdentifier
        if isFrontmost,
           hasVisibleDashboardWindow(),
           hasUsableAccessibilityWindow(in: appElement),
           hasMeaningfulWorkspaceAccessibilityTree(in: appElement) {
            stableSamples += 1
            if stableSamples >= 2 {
                return
            }
        } else {
            stableSamples = 0
        }
        Thread.sleep(forTimeInterval: 0.10)
    } while Date() < deadline
}

private func hasMeaningfulWorkspaceAccessibilityTree(in appElement: AXUIElement) -> Bool {
    guard findElement(in: appElement, maxDepth: 32, maxNodes: 35_000, where: {
        identifierMatches(stringAttribute($0, "AXIdentifier" as CFString), expected: "workspace-dashboard")
    }) != nil else {
        return false
    }
    return workspaceTargets.contains { target in
        guard let content = findElement(in: appElement, maxDepth: 32, maxNodes: 35_000, where: {
            identifierMatches(
                stringAttribute($0, "AXIdentifier" as CFString),
                expected: target.contentRootIdentifier
            )
        }),
        let frame = accessibilityFrameIncludingDescendants(of: content) else {
            return false
        }
        return isMeaningful(frame)
    }
}

private func activateApplicationBundle() {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/usr/bin/open")
    if let appPath, !appPath.isEmpty {
        process.arguments = ["-n", appPath]
    } else {
        process.arguments = ["-b", bundleID]
    }
    process.standardOutput = Pipe()
    process.standardError = Pipe()
    try? process.run()
    process.waitUntilExit()
}

private func activateApplicationWithAppleScript() {
    // When a concrete bundle path is supplied, NSWorkspace/open and the AX
    // frontmost attribute already target the exact process. Resolving an app
    // by display name can select another installed KLMS Sync build or block
    // indefinitely when both builds are running.
    if let appPath, !appPath.isEmpty {
        return
    }
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
    if let appPath, !appPath.isEmpty {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/open")
        process.arguments = [appPath]
        process.standardOutput = Pipe()
        process.standardError = Pipe()
        try? process.run()
        process.waitUntilExit()
        return
    }
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
        if let targetProcessIdentifier {
            let ownerPID = (info[kCGWindowOwnerPID as String] as? NSNumber)?.int32Value
            guard ownerPID == targetProcessIdentifier else { return false }
        }
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

        var requiredIdentifiers = [target.renderedIdentifier]
        if target.rawValue == "dashboard" {
            requiredIdentifiers.append(primarySyncActionIdentifier)
        }
        guard waitForElements(withIdentifiers: requiredIdentifiers, in: appElement, timeout: timeout) else {
            for identifier in requiredIdentifiers where waitForElement(withIdentifier: identifier, in: appElement, timeout: 0.1) == nil {
                throw SmokeFailure.workspaceContentMissing(identifier)
            }
            throw SmokeFailure.workspaceContentMissing(requiredIdentifiers.joined(separator: ", "))
        }

        Thread.sleep(forTimeInterval: navigationDelay)
        let expectedPrimaryActionCount = target.rawValue == "dashboard" ? 1 : 0
        guard waitForElementCount(
            identifier: primarySyncActionIdentifier,
            expectedCount: expectedPrimaryActionCount,
            in: appElement,
            timeout: timeout
        ) else {
            let primaryActionCount = countElements(
                in: appElement,
                maxDepth: 32,
                maxNodes: 35_000,
                where: {
                    identifierMatches(
                        stringAttribute($0, "AXIdentifier" as CFString),
                        expected: primarySyncActionIdentifier
                    )
                }
            )
            throw SmokeFailure.layoutOverlap(
                "Expected \(expectedPrimaryActionCount) dashboard sync actions in \(target.rawValue), found \(primaryActionCount)."
            )
        }
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
            guard waitForStableWorkspaceContent(
                rootIdentifier: target.renderedIdentifier,
                in: appElement
            ) else {
                throw SmokeFailure.workspaceContentMissing(target.renderedIdentifier)
            }
            try verifyWorkspaceContentLayout(appElement: appElement, target: target)
            try waitForSettledWorkspaceNavigation(appElement: appElement)
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

private func verifyAdaptiveResize(appElement: AXUIElement) throws {
    guard let window = firstAccessibilityWindow(in: appElement),
          let originalFrame = accessibilityFrame(of: window) else {
        throw SmokeFailure.layoutOverlap("Could not find the KLMS window for adaptive resize verification.")
    }
    defer {
        try? setAccessibilityWindowSize(originalFrame.size, window: window)
        try? setAccessibilityWindowPosition(originalFrame.origin, window: window)
    }

    let verificationWidths: [(width: CGFloat, mode: String)] = [
        (1_200, "wide"),
        (900, "medium"),
        (640, "compact"),
    ]
    let verificationHeight = max(720, originalFrame.height)

    try verifyNavigationTransitionRanges(
        appElement: appElement,
        window: window,
        height: verificationHeight
    )
    try verifyLogClearActionTransitionRanges(
        appElement: appElement,
        window: window,
        height: verificationHeight
    )

    for target in workspaceTargets {
        try setAccessibilityWindowSize(
            CGSize(width: 1_200, height: verificationHeight),
            window: window
        )
        try verifyWorkspaceNavigation(appElement: appElement, target: target)

        for verification in verificationWidths {
            try setAccessibilityWindowSize(
                CGSize(width: verification.width, height: verificationHeight),
                window: window
            )
            guard waitForStableWorkspaceContent(
                rootIdentifier: target.renderedIdentifier,
                layoutMode: verification.mode,
                in: appElement
            ) else {
                throw SmokeFailure.layoutOverlap(
                    "Workspace \(target.rawValue) did not preserve its \(verification.mode) layout at width \(Int(verification.width))."
                )
            }

            if verification.mode == "compact" {
                guard waitForElementAbsence(
                    identifiers: [
                        "workspace-navigation-mode-rail",
                        "workspace-navigation-mode-sidebar",
                    ],
                    in: appElement,
                    timeout: timeout
                ) else {
                    throw SmokeFailure.layoutOverlap("Compact workspace menu did not render after live window resize.")
                }
            }

            try verifyWorkspaceContentLayout(appElement: appElement, target: target)
            try verifyHorizontalDescendantContainment(
                appElement: appElement,
                rootIdentifier: target.contentRootIdentifier,
                viewportIdentifier: target.scrollIdentifier,
                context: "workspace \(target.rawValue) at width \(Int(verification.width))"
            )
            if target.rawValue == "activityLogs" {
                try verifyLogClearAction(
                    appElement: appElement,
                    rootIdentifier: target.contentRootIdentifier,
                    viewportIdentifier: target.scrollIdentifier,
                    mode: verification.mode
                )
            }
            if target.rawValue == "dashboard" {
                try verifyPrimarySyncActionLayout(appElement: appElement, mode: verification.mode)
            }
            try captureScreenshotIfRequested(
                named: "matrix-\(target.rawValue)-\(Int(verification.width))"
            )
        }
    }

    try setAccessibilityWindowSize(
        CGSize(width: 1_200, height: verificationHeight),
        window: window
    )
    try verifyWorkspaceNavigation(appElement: appElement, target: workspaceTargets[7])
    for settingsTarget in settingsTargets {
        try setAccessibilityWindowSize(
            CGSize(width: 1_200, height: verificationHeight),
            window: window
        )
        try verifySettingsTabNavigation(
            appElement: appElement,
            identifier: settingsTarget.identifier,
            expectedText: settingsTarget.expectedText
        )
        for verification in verificationWidths {
            try setAccessibilityWindowSize(
                CGSize(width: verification.width, height: verificationHeight),
                window: window
            )
            guard waitForStableWorkspaceContent(
                rootIdentifier: "workspace-content-root-settings",
                layoutMode: verification.mode,
                in: appElement
            ) else {
                throw SmokeFailure.workspaceContentMissing("workspace-content-root-settings")
            }
            guard waitForSelectedValue(
                identifier: settingsTarget.identifier,
                in: appElement,
                timeout: timeout
            ) else {
                throw SmokeFailure.selectedValueMissing(settingsTarget.identifier)
            }
            try verifyHorizontalDescendantContainment(
                appElement: appElement,
                rootIdentifier: "workspace-content-root-settings",
                viewportIdentifier: "workspace-scroll-settings",
                context: "settings \(settingsTarget.rawValue) at width \(Int(verification.width))"
            )
            try captureScreenshotIfRequested(
                named: "matrix-settings-\(settingsTarget.rawValue)-\(Int(verification.width))"
            )
        }
    }

    print("ok: all workspaces and settings tabs stay inside 1200/900/640pt viewports")
}

private func waitForSettledWorkspaceNavigation(appElement: AXUIElement) throws {
    guard waitForElement(
        withIdentifier: "workspace-navigation-mode-sidebar",
        in: appElement,
        timeout: 0.1
    ) != nil else {
        return
    }

    let deadline = Date().addingTimeInterval(timeout)
    var previousSignature: String?
    var stableSamples = 0
    repeat {
        var signatureParts: [String] = []
        var complete = true
        for target in workspaceTargets {
            guard let element = waitForElement(
                withIdentifier: target.buttonIdentifier,
                in: appElement,
                timeout: 0.1
            ),
            let frame = accessibilityFrame(of: element),
            isMeaningful(frame),
            textAttributes(of: element).contains(where: {
                $0.localizedCaseInsensitiveContains(target.title)
            }) else {
                complete = false
                break
            }
            signatureParts.append(
                "\(target.rawValue):\(Int(frame.minX)),\(Int(frame.minY)),\(Int(frame.width)),\(Int(frame.height))"
            )
        }

        if complete {
            let signature = signatureParts.joined(separator: "|")
            if signature == previousSignature {
                stableSamples += 1
                if stableSamples >= 2 {
                    Thread.sleep(forTimeInterval: 0.15)
                    return
                }
            } else {
                previousSignature = signature
                stableSamples = 1
            }
        } else {
            previousSignature = nil
            stableSamples = 0
        }
        Thread.sleep(forTimeInterval: 0.1)
    } while Date() < deadline

    throw SmokeFailure.layoutOverlap(
        "Workspace sidebar labels and icons did not reach a stable rendered state before capture."
    )
}

private func verifyNavigationTransitionRanges(
    appElement: AXUIElement,
    window: AXUIElement,
    height: CGFloat
) throws {
    let dashboard = workspaceTargets[0]
    try setAccessibilityWindowSize(CGSize(width: 1_200, height: height), window: window)
    try verifyWorkspaceNavigation(appElement: appElement, target: dashboard)

    let samples: [(label: String, width: CGFloat, contentMode: String, navigationMode: String?, navigationWidth: CGFloat)] = [
        ("640", 640, "compact", nil, 0),
        ("720", 720, "compact", nil, 0),
        ("759", 759, "medium", nil, 0),
        ("760", 760, "compact", "rail", 65),
        ("1199", 1_199, "wide", "rail", 65),
        ("1200", 1_200, "wide", "sidebar", 185),
    ]

    for sample in samples {
        try setAccessibilityWindowSize(CGSize(width: sample.width, height: height), window: window)
        guard waitForStableWorkspaceContent(
            rootIdentifier: dashboard.contentRootIdentifier,
            layoutMode: sample.contentMode,
            in: appElement
        ) else {
            throw SmokeFailure.layoutOverlap(
                "Content mode \(sample.contentMode) is missing at transition width \(sample.label)."
            )
        }
        if let navigationMode = sample.navigationMode {
            let navigationIdentifier = "workspace-navigation-mode-\(navigationMode)"
            guard let navigation = waitForElement(
                withIdentifier: navigationIdentifier,
                in: appElement,
                timeout: timeout
            ),
            let navigationFrame = accessibilityFrame(of: navigation),
            let contentRoot = waitForElement(
                withIdentifier: dashboard.contentRootIdentifier,
                in: appElement,
                timeout: timeout
            ),
            let contentFrame = accessibilityFrameIncludingDescendants(of: contentRoot),
            abs(navigationFrame.width - sample.navigationWidth) <= 2,
            abs(contentFrame.minX - navigationFrame.maxX) <= 2 else {
                throw SmokeFailure.layoutOverlap(
                    "Navigation \(navigationMode) must be exactly \(Int(sample.navigationWidth))pt and meet the document edge at transition width \(sample.label)."
                )
            }
        } else {
            guard waitForElementAbsence(
                identifiers: [
                    "workspace-navigation-mode-rail",
                    "workspace-navigation-mode-sidebar",
                ],
                in: appElement,
                timeout: timeout
            ) else {
                throw SmokeFailure.layoutOverlap(
                    "Compact navigation is missing at transition width \(sample.label)."
                )
            }
            guard let contentRoot = waitForElement(
                withIdentifier: dashboard.contentRootIdentifier,
                in: appElement,
                timeout: timeout
            ),
            let contentFrame = accessibilityFrameIncludingDescendants(of: contentRoot),
            abs(contentFrame.width - sample.width) <= 2 else {
                throw SmokeFailure.layoutOverlap(
                    "Hidden navigation must be exactly 0pt at transition width \(sample.label)."
                )
            }
            if sample.width == 720 {
                try verifyCompactWorkspaceMenuOptions(appElement: appElement)
            }
        }
        try verifyHorizontalDescendantContainment(
            appElement: appElement,
            rootIdentifier: dashboard.contentRootIdentifier,
            viewportIdentifier: dashboard.scrollIdentifier,
            context: "dashboard transition width \(sample.label)"
        )
        try captureScreenshotIfRequested(named: "transition-\(sample.label)")
    }

    try verifyRepeatedNavigationBoundaryCrossings(
        appElement: appElement,
        window: window,
        height: height,
        dashboard: dashboard
    )
}

private func verifyRepeatedNavigationBoundaryCrossings(
    appElement: AXUIElement,
    window: AXUIElement,
    height: CGFloat,
    dashboard: WorkspaceSmokeTarget
) throws {
    let samples: [(width: CGFloat, contentMode: String, navigationMode: String?)] = [
        (759, "medium", nil),
        (760, "compact", "rail"),
        (1_199, "wide", "rail"),
        (1_200, "wide", "sidebar"),
    ]

    for crossing in 0..<20 {
        let sample = samples[crossing % samples.count]
        try setAccessibilityWindowSize(CGSize(width: sample.width, height: height), window: window)
        guard waitForStableWorkspaceContent(
            rootIdentifier: dashboard.contentRootIdentifier,
            layoutMode: sample.contentMode,
            in: appElement
        ) else {
            throw SmokeFailure.layoutOverlap(
                "Repeated resize crossing \(crossing + 1) lost content mode \(sample.contentMode)."
            )
        }
        if let navigationMode = sample.navigationMode {
            guard waitForElement(
                withIdentifier: "workspace-navigation-mode-\(navigationMode)",
                in: appElement,
                timeout: timeout
            ) != nil else {
                throw SmokeFailure.layoutOverlap(
                    "Repeated resize crossing \(crossing + 1) lost navigation mode \(navigationMode)."
                )
            }
        } else {
            guard waitForElementAbsence(
                identifiers: ["workspace-navigation-mode-rail", "workspace-navigation-mode-sidebar"],
                in: appElement,
                timeout: timeout
            ) else {
                throw SmokeFailure.layoutOverlap(
                    "Repeated resize crossing \(crossing + 1) did not hide navigation."
                )
            }
        }
        let selectionIsPreserved: Bool
        if sample.navigationMode == nil {
            selectionIsPreserved = waitForElement(
                withIdentifier: dashboard.renderedIdentifier,
                in: appElement,
                timeout: timeout
            ) != nil && waitForElement(
                withIdentifier: "workspace-compact-menu",
                in: appElement,
                timeout: timeout
            ) != nil
        } else {
            selectionIsPreserved = waitForSelectedValue(
                identifier: dashboard.buttonIdentifier,
                in: appElement,
                timeout: 0.5
            )
        }
        guard selectionIsPreserved else {
            throw SmokeFailure.layoutOverlap(
                "Repeated resize crossing \(crossing + 1) lost the selected workspace."
            )
        }
    }
}

private func verifyCompactWorkspaceMenuOptions(appElement: AXUIElement) throws {
    guard let menu = waitForElement(
        withIdentifier: "workspace-compact-menu",
        in: appElement,
        timeout: timeout
    ) else {
        throw SmokeFailure.layoutOverlap("Narrow workspace menu is missing.")
    }
    guard AXUIElementPerformAction(menu, kAXPressAction as CFString) == .success else {
        throw SmokeFailure.layoutOverlap("Narrow workspace menu could not be opened.")
    }

    var firstItem: AXUIElement?
    for target in workspaceTargets {
        let identifier = "workspace-compact-\(target.rawValue)"
        guard let item = waitForElement(
            withIdentifier: identifier,
            in: appElement,
            timeout: timeout
        ) else {
            throw SmokeFailure.layoutOverlap(
                "Narrow workspace menu is missing section \(target.title)."
            )
        }
        if firstItem == nil {
            firstItem = item
        }
    }

    if let firstItem {
        _ = AXUIElementPerformAction(firstItem, kAXPressAction as CFString)
    }
    guard waitForElement(
        withIdentifier: workspaceTargets[0].contentRootIdentifier,
        in: appElement,
        timeout: timeout
    ) != nil else {
        throw SmokeFailure.layoutOverlap("Narrow workspace menu did not preserve selection state.")
    }
}

private func verifyLogClearActionTransitionRanges(
    appElement: AXUIElement,
    window: AXUIElement,
    height: CGFloat
) throws {
    let target = workspaceTargets.first { $0.rawValue == "activityLogs" }!
    try setAccessibilityWindowSize(CGSize(width: 1_200, height: height), window: window)
    try verifyWorkspaceNavigation(appElement: appElement, target: target)

    let samples: [(width: CGFloat, mode: String)] = [
        (720, "compact"),
        (1_040, "wide"),
        (1_240, "wide"),
    ]
    for sample in samples {
        try setAccessibilityWindowSize(CGSize(width: sample.width, height: height), window: window)
        guard waitForStableWorkspaceContent(
            rootIdentifier: target.contentRootIdentifier,
            layoutMode: sample.mode,
            in: appElement
        ) else {
            throw SmokeFailure.layoutOverlap(
                "Activity logs did not preserve their \(sample.mode) layout at width \(Int(sample.width))."
            )
        }
        try verifyHorizontalDescendantContainment(
            appElement: appElement,
            rootIdentifier: target.contentRootIdentifier,
            viewportIdentifier: target.scrollIdentifier,
            context: "activity logs at width \(Int(sample.width))"
        )
        try verifyLogClearAction(
            appElement: appElement,
            rootIdentifier: target.contentRootIdentifier,
            viewportIdentifier: target.scrollIdentifier,
            mode: sample.mode
        )
        try captureScreenshotIfRequested(named: "log-clear-\(Int(sample.width))")
    }
}

private func verifyLogClearAction(
    appElement: AXUIElement,
    rootIdentifier: String,
    viewportIdentifier: String,
    mode: String
) throws {
    guard let action = waitForElement(
        withIdentifier: "log-clear-all-action",
        in: appElement,
        timeout: timeout
    ),
    let actionFrame = accessibilityFrame(of: action),
    let viewport = waitForElement(
        withIdentifier: viewportIdentifier,
        in: appElement,
        timeout: 0.2
    ) ?? waitForElement(
        withIdentifier: rootIdentifier,
        in: appElement,
        timeout: timeout
    ),
    let viewportFrame = accessibilityFrame(of: viewport),
    isMeaningful(actionFrame),
    isMeaningful(viewportFrame) else {
        throw SmokeFailure.layoutOverlap("The compact trailing clear-all log action is missing in \(mode) layout.")
    }

    guard actionFrame.width >= 44,
          actionFrame.height >= 44,
          actionFrame.minX >= viewportFrame.minX - 2,
          actionFrame.maxX <= viewportFrame.maxX + 2 else {
        throw SmokeFailure.layoutOverlap(
            "The clear-all log action lost its 44pt target or escaped the \(mode) viewport: action=\(actionFrame.debugDescription), viewport=\(viewportFrame.debugDescription)."
        )
    }

    let expectedPresentation = mode == "compact" ? "아이콘 전용" : "아이콘과 레이블"
    guard textAttributes(of: action).contains(where: {
        $0.localizedCaseInsensitiveContains(expectedPresentation)
    }) else {
        throw SmokeFailure.layoutOverlap(
            "The clear-all log action did not expose its \(expectedPresentation) presentation in \(mode) layout."
        )
    }
}

private func verifyPrimarySyncActionLayout(appElement: AXUIElement, mode: String) throws {
    guard let action = waitForElement(
        withIdentifier: primarySyncActionIdentifier,
        in: appElement,
        timeout: timeout
    ),
    let actionFrame = accessibilityFrame(of: action),
    let commandColumn = waitForElement(
        withIdentifier: "dashboard-command-column",
        in: appElement,
        timeout: timeout
    ),
    let commandColumnFrame = accessibilityFrame(of: commandColumn),
    let summaryColumn = waitForElement(
        withIdentifier: "dashboard-summary-column",
        in: appElement,
        timeout: timeout
    ),
    let summaryColumnFrame = accessibilityFrame(of: summaryColumn),
    let viewportFrame = workspaceViewportFrame(
        in: appElement,
        identifiers: [
            "workspace-scroll-dashboard",
            "workspace-content-root-dashboard",
            "workspace-container-dashboard",
        ],
        timeout: timeout
    ),
    isMeaningful(actionFrame),
    isMeaningful(commandColumnFrame),
    isMeaningful(summaryColumnFrame),
    isMeaningful(viewportFrame) else {
        throw SmokeFailure.layoutOverlap("The dashboard sync card or adaptive column frame is missing in \(mode) layout.")
    }

    guard actionFrame.minY >= viewportFrame.minY - 4,
          actionFrame.maxY <= viewportFrame.maxY + 4 else {
        throw SmokeFailure.layoutOverlap(
            "The dashboard sync card is not inside the workspace scroll area in \(mode) layout."
        )
    }

    guard actionFrame.minX >= commandColumnFrame.minX - 4,
          actionFrame.maxX <= commandColumnFrame.maxX + 4,
          actionFrame.minY >= commandColumnFrame.minY - 4,
          actionFrame.maxY <= commandColumnFrame.maxY + 4 else {
        throw SmokeFailure.layoutOverlap(
            "The full-sync action escaped the dashboard command column in \(mode) layout."
        )
    }

    if mode == "wide" {
        guard abs(commandColumnFrame.minY - summaryColumnFrame.minY) <= 4 else {
            throw SmokeFailure.layoutOverlap(
                "The wide dashboard columns no longer share their original top alignment."
            )
        }
    } else {
        guard commandColumnFrame.maxY <= summaryColumnFrame.minY + 4 else {
            throw SmokeFailure.layoutOverlap(
                "The sync section is not above the dashboard summary in \(mode) one-column layout."
            )
        }
    }

    if mode == "compact" {
        guard actionFrame.width >= commandColumnFrame.width - 40 else {
            throw SmokeFailure.layoutOverlap(
                "The compact full-sync card does not fill its command column: \(Int(actionFrame.width)) of \(Int(commandColumnFrame.width))."
            )
        }
        if let compactMenu = waitForElement(
            withIdentifier: "workspace-compact-menu",
            in: appElement,
            timeout: 0.2
        ),
        let compactMenuFrame = accessibilityFrame(of: compactMenu),
        isMeaningful(compactMenuFrame),
        actionFrame.minY < compactMenuFrame.maxY - 2 {
            throw SmokeFailure.layoutOverlap("The compact primary sync action overlaps the workspace menu.")
        }
    }

    if let utilities = waitForElement(
        withIdentifier: "top-utility-actions",
        in: appElement,
        timeout: 0.2
    ),
    let utilityFrame = accessibilityFrame(of: utilities),
    isMeaningful(utilityFrame) {
        let intersection = actionFrame.intersection(utilityFrame)
        if !intersection.isNull,
           intersection.width > 4,
           intersection.height > 4 {
            throw SmokeFailure.layoutOverlap(
                "The primary sync action overlaps the top utility actions in \(mode) layout."
            )
        }
    }
}

private func firstAccessibilityWindow(in appElement: AXUIElement) -> AXUIElement? {
    var value: CFTypeRef?
    guard AXUIElementCopyAttributeValue(appElement, kAXWindowsAttribute as CFString, &value) == .success,
          let windows = value as? [AXUIElement] else {
        return nil
    }
    return windows
        .filter { stringAttribute($0, kAXRoleAttribute as CFString) == kAXWindowRole }
        .compactMap { window -> (window: AXUIElement, area: CGFloat)? in
            guard let frame = accessibilityFrame(of: window), isMeaningful(frame) else { return nil }
            return (window, frame.width * frame.height)
        }
        .max { $0.area < $1.area }?
        .window
}

private func setAccessibilityWindowSize(_ requestedSize: CGSize, window: AXUIElement) throws {
    try ensureAccessibilityWindowFits(requestedSize, window: window)
    var size = requestedSize
    guard let value = AXValueCreate(.cgSize, &size) else {
        throw SmokeFailure.layoutOverlap("Could not create an accessibility window-size value.")
    }
    let error = AXUIElementSetAttributeValue(window, kAXSizeAttribute as CFString, value)
    guard error == .success else {
        throw SmokeFailure.layoutOverlap("Could not resize the KLMS window through Accessibility: \(error).")
    }

    let deadline = Date().addingTimeInterval(timeout)
    let sizeTolerance: CGFloat = 0.1
    var stableSamples = 0
    repeat {
        if let frame = accessibilityFrame(of: window),
           abs(frame.width - requestedSize.width) <= sizeTolerance,
           abs(frame.height - requestedSize.height) <= sizeTolerance {
            stableSamples += 1
            if stableSamples >= 2 {
                Thread.sleep(forTimeInterval: 0.25)
                return
            }
        } else {
            stableSamples = 0
        }
        Thread.sleep(forTimeInterval: 0.05)
    } while Date() < deadline
    let actualWidth = accessibilityFrame(of: window)?.width ?? 0
    throw SmokeFailure.layoutOverlap(
        "KLMS window did not reach requested width \(Int(requestedSize.width)); actual=\(Int(actualWidth))."
    )
}

private func ensureAccessibilityWindowFits(_ requestedSize: CGSize, window: AXUIElement) throws {
    guard let currentFrame = accessibilityFrame(of: window) else {
        return
    }

    let displayFrame = activeDisplayBounds(
        containing: CGPoint(x: currentFrame.midX, y: currentFrame.midY)
    )
    let horizontalInset: CGFloat = 12
    let topInset: CGFloat = 40
    let bottomInset: CGFloat = 24
    let minimumX = displayFrame.minX + horizontalInset
    let maximumX = displayFrame.maxX - requestedSize.width - horizontalInset
    let minimumY = displayFrame.minY + topInset
    let maximumY = displayFrame.maxY - requestedSize.height - bottomInset
    let targetX = maximumX >= minimumX
        ? min(max(currentFrame.minX, minimumX), maximumX)
        : displayFrame.minX
    let targetY = maximumY >= minimumY
        ? min(max(currentFrame.minY, minimumY), maximumY)
        : displayFrame.minY
    guard abs(currentFrame.minX - targetX) > 1 || abs(currentFrame.minY - targetY) > 1 else {
        return
    }

    try setAccessibilityWindowPosition(CGPoint(x: targetX, y: targetY), window: window)
}

private func setAccessibilityWindowPosition(_ requestedPosition: CGPoint, window: AXUIElement) throws {
    var position = requestedPosition
    guard let value = AXValueCreate(.cgPoint, &position) else {
        throw SmokeFailure.layoutOverlap("Could not create an accessibility window-position value.")
    }
    let error = AXUIElementSetAttributeValue(window, kAXPositionAttribute as CFString, value)
    guard error == .success else {
        throw SmokeFailure.layoutOverlap("Could not reposition the KLMS window before resizing: \(error).")
    }

    let deadline = Date().addingTimeInterval(min(timeout, 1.0))
    repeat {
        if let frame = accessibilityFrame(of: window),
           abs(frame.minX - requestedPosition.x) <= 2,
           abs(frame.minY - requestedPosition.y) <= 2 {
            return
        }
        Thread.sleep(forTimeInterval: 0.05)
    } while Date() < deadline
    throw SmokeFailure.layoutOverlap("KLMS window did not reach its safe resize position.")
}

private func activeDisplayBounds(containing point: CGPoint) -> CGRect {
    var count: UInt32 = 0
    guard CGGetActiveDisplayList(0, nil, &count) == .success, count > 0 else {
        return CGDisplayBounds(CGMainDisplayID())
    }
    var displays = Array(repeating: CGDirectDisplayID(), count: Int(count))
    guard CGGetActiveDisplayList(count, &displays, &count) == .success else {
        return CGDisplayBounds(CGMainDisplayID())
    }
    return displays
        .prefix(Int(count))
        .map(CGDisplayBounds)
        .first(where: { $0.contains(point) })
        ?? CGDisplayBounds(CGMainDisplayID())
}

private func verifyWorkspaceContentLayout(
    appElement: AXUIElement,
    target: WorkspaceSmokeTarget
) throws {
    let nativeScrollFrame = meaningfulAccessibilityFrame(
        identifier: target.scrollIdentifier,
        in: appElement,
        timeout: 0.4
    )
    guard let scrollFrame = nativeScrollFrame ?? meaningfulAccessibilityFrame(
              identifier: target.renderedIdentifier,
              in: appElement,
              timeout: timeout
          ),
          isMeaningful(scrollFrame) else {
        throw SmokeFailure.layoutOverlap("workspace \(target.rawValue) layout frame is missing from the accessibility tree.")
    }

    if nativeScrollFrame != nil {
        guard scrollFrame.width >= 420, scrollFrame.height >= 240 else {
            throw SmokeFailure.layoutOverlap(
                "workspace \(target.rawValue) scroll area is too small: \(Int(scrollFrame.width))x\(Int(scrollFrame.height))."
            )
        }
    } else {
        guard scrollFrame.width >= 360, scrollFrame.height >= 80 else {
            throw SmokeFailure.layoutOverlap(
                "workspace \(target.rawValue) content frame is too small: \(Int(scrollFrame.width))x\(Int(scrollFrame.height))."
            )
        }
    }

    let buttonFrame = waitForElement(
        withIdentifier: target.buttonIdentifier,
        in: appElement,
        timeout: 0.2
    ).flatMap(accessibilityFrame)
    if let buttonFrame, isMeaningful(buttonFrame) {
        guard scrollFrame.minX >= buttonFrame.maxX - 16 else {
            throw SmokeFailure.layoutOverlap(
                "workspace \(target.rawValue) scroll area overlaps the sidebar."
            )
        }
    }

    let horizontalSlack: CGFloat = 10
    if let panel = waitForElement(withIdentifier: target.panelIdentifier, in: appElement, timeout: 0.2),
       let panelFrame = accessibilityFrameIncludingDescendants(of: panel),
       isMeaningful(panelFrame) {
        guard panelFrame.width >= 360, panelFrame.height >= 80 else {
            throw SmokeFailure.layoutOverlap(
                "workspace \(target.rawValue) panel frame is too small: \(Int(panelFrame.width))x\(Int(panelFrame.height))."
            )
        }
        guard panelFrame.minX >= scrollFrame.minX - horizontalSlack,
              panelFrame.maxX <= scrollFrame.maxX + horizontalSlack else {
            throw SmokeFailure.layoutOverlap(
                "workspace \(target.rawValue) panel is outside the scroll area."
            )
        }
    }

    if let container = waitForElement(withIdentifier: target.renderedIdentifier, in: appElement, timeout: 0.2),
       let containerFrame = accessibilityFrameIncludingDescendants(of: container),
       isMeaningful(containerFrame),
       containerFrame.width < 360 {
        throw SmokeFailure.layoutOverlap(
            "workspace \(target.rawValue) container frame is too narrow: \(Int(containerFrame.width))."
        )
    }

    if let buttonFrame, isMeaningful(buttonFrame) {
        let navIntersection = buttonFrame.intersection(scrollFrame)
        if !navIntersection.isNull, isMeaningful(navIntersection),
           navIntersection.width > 4,
           navIntersection.height > 4 {
            throw SmokeFailure.layoutOverlap(
                "workspace \(target.rawValue) scroll area overlaps the sidebar button \(target.buttonIdentifier)."
            )
        }
    }
}

private func workspaceViewportFrame(
    in appElement: AXUIElement,
    identifiers: [String],
    timeout: TimeInterval
) -> CGRect? {
    let deadline = Date().addingTimeInterval(timeout)
    repeat {
        for identifier in identifiers {
            if let element = waitForElement(withIdentifier: identifier, in: appElement, timeout: 0.1),
               let frame = accessibilityFrameIncludingDescendants(of: element),
               isMeaningful(frame) {
                return frame
            }
        }
        Thread.sleep(forTimeInterval: 0.05)
    } while Date() < deadline
    return nil
}

private func meaningfulAccessibilityFrame(
    identifier: String,
    in appElement: AXUIElement,
    timeout: TimeInterval
) -> CGRect? {
    let deadline = Date().addingTimeInterval(timeout)
    repeat {
        if let element = waitForElement(
            withIdentifier: identifier,
            in: appElement,
            timeout: min(0.15, timeout)
        ),
        let frame = accessibilityFrameIncludingDescendants(of: element),
        isMeaningful(frame) {
            return frame
        }
        Thread.sleep(forTimeInterval: 0.05)
    } while Date() < deadline
    return nil
}

private func verifyHorizontalDescendantContainment(
    appElement: AXUIElement,
    rootIdentifier: String,
    viewportIdentifier: String,
    context: String
) throws {
    guard let root = waitForElement(
        withIdentifier: rootIdentifier,
        in: appElement,
        timeout: timeout
    ) else {
        throw SmokeFailure.layoutOverlap(
            "\(context): content root is missing."
        )
    }
    let viewport = waitForElement(
        withIdentifier: viewportIdentifier,
        in: appElement,
        timeout: 0.2
    ) ?? root
    let directViewportFrame = accessibilityFrame(of: viewport)
    let fallbackWindowFrame = firstAccessibilityWindow(in: appElement)
        .flatMap(accessibilityFrame)
    guard let viewportFrame = directViewportFrame.flatMap({ isMeaningful($0) ? $0 : nil })
            ?? fallbackWindowFrame.flatMap({ isMeaningful($0) ? $0 : nil }) else {
        throw SmokeFailure.layoutOverlap(
            "\(context): content root or native workspace viewport is missing."
        )
    }

    let horizontalSlack: CGFloat = 2
    var stack: [(AXUIElement, Int)] = [(root, 0)]
    var visited = Set<AXUIElement>()
    var visitedCount = 0
    var offenders: [String] = []

    while let (element, depth) = stack.popLast() {
        guard visited.insert(element).inserted else { continue }
        visitedCount += 1
        guard visitedCount <= 35_000 else {
            throw SmokeFailure.layoutOverlap(
                "\(context): accessibility containment traversal exceeded 35000 nodes."
            )
        }

        if boolAttribute(element, "AXVisible" as CFString) != false,
           let frame = accessibilityFrame(of: element),
           isMeaningful(frame),
           (frame.minX < viewportFrame.minX - horizontalSlack
            || frame.maxX > viewportFrame.maxX + horizontalSlack
            || frame.width > viewportFrame.width + (horizontalSlack * 2)) {
            offenders.append(
                "\(accessibilityElementSummary(element)) frame=\(frame.debugDescription)"
            )
            if offenders.count >= 8 { break }
        }

        guard depth < 40 else { continue }
        for child in childElements(of: element).reversed() {
            stack.append((child, depth + 1))
        }
    }

    guard offenders.isEmpty else {
        throw SmokeFailure.layoutOverlap(
            "\(context): descendants escaped viewport \(viewportFrame.debugDescription): \(offenders.joined(separator: "; "))"
        )
    }
}

private func accessibilityElementSummary(_ element: AXUIElement) -> String {
    let role = stringAttribute(element, kAXRoleAttribute as CFString) ?? "unknown-role"
    let identifier = stringAttribute(element, "AXIdentifier" as CFString) ?? "no-id"
    let title = textAttributes(of: element).first ?? "no-title"
    return "role=\(role) id=\(identifier) title=\(title)"
}

private func boolAttribute(_ element: AXUIElement, _ attribute: CFString) -> Bool? {
    var value: CFTypeRef?
    guard AXUIElementCopyAttributeValue(element, attribute, &value) == .success else {
        return nil
    }
    return (value as? NSNumber)?.boolValue
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

private func accessibilityFrameIncludingDescendants(of element: AXUIElement) -> CGRect? {
    if let frame = accessibilityFrame(of: element), isMeaningful(frame) {
        return frame
    }

    var stack = childElements(of: element).map { ($0, 1) }
    var visited = Set<AXUIElement>()
    var visitedCount = 0
    var combinedFrame: CGRect?
    while let (candidate, depth) = stack.popLast() {
        guard visited.insert(candidate).inserted else { continue }
        visitedCount += 1
        guard visitedCount <= 35_000 else { break }

        if boolAttribute(candidate, "AXVisible" as CFString) != false,
           let frame = accessibilityFrame(of: candidate),
           isMeaningful(frame) {
            combinedFrame = combinedFrame?.union(frame) ?? frame
        }
        guard depth < 32 else { continue }
        for child in childElements(of: candidate).reversed() {
            stack.append((child, depth + 1))
        }
    }
    return combinedFrame
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
    try FileManager.default.setAttributes(
        [.posixPermissions: 0o700],
        ofItemAtPath: screenshotDirectoryURL.path
    )
    if let targetProcessIdentifier {
        let appElement = AXUIElementCreateApplication(targetProcessIdentifier)
        if let window = firstAccessibilityWindow(in: appElement),
           let frame = accessibilityFrame(of: window) {
            try ensureAccessibilityWindowFits(frame.size, window: window)
            Thread.sleep(forTimeInterval: 0.1)
        }
    }
    guard let windowID = waitForVisibleDashboardWindowID() else {
        throw SmokeFailure.screenshotFailed("Could not find a visible KLMS Sync window to capture.")
    }
    let safeName = rawName
        .replacingOccurrences(of: "[^A-Za-z0-9._-]+", with: "-", options: .regularExpression)
        .trimmingCharacters(in: CharacterSet(charactersIn: "-"))
    let outputURL = screenshotDirectoryURL.appendingPathComponent("\(safeName).png")
    var captured = false
    for attempt in 0..<3 {
        try? FileManager.default.removeItem(at: outputURL)
        captured = captureWindowUsingScreencapture(windowID: windowID, to: outputURL)
        if captured {
            break
        }
        Thread.sleep(forTimeInterval: 0.2 * Double(attempt + 1))
    }
    guard captured,
          FileManager.default.fileExists(atPath: outputURL.path) else {
        throw SmokeFailure.screenshotFailed("Could not capture KLMS Sync screenshot for '\(rawName)'.")
    }
    try FileManager.default.setAttributes(
        [.posixPermissions: 0o600],
        ofItemAtPath: outputURL.path
    )
    restoreTargetApplicationAfterCaptureIfNeeded()
    print("screenshot: \(outputURL.path)")
}

private func restoreTargetApplicationAfterCaptureIfNeeded() {
    guard let targetProcessIdentifier,
          let app = NSRunningApplication(processIdentifier: targetProcessIdentifier),
          !app.isTerminated,
          NSWorkspace.shared.frontmostApplication?.processIdentifier != targetProcessIdentifier
            || !hasVisibleDashboardWindow()
            || !hasUsableAccessibilityWindow(in: AXUIElementCreateApplication(targetProcessIdentifier)) else {
        return
    }
    bringKLMSAppForward(
        app: app,
        appElement: AXUIElementCreateApplication(targetProcessIdentifier)
    )
}

private func waitForVisibleDashboardWindowID() -> Int? {
    if let windowID = visibleDashboardWindowID() {
        return windowID
    }

    requestDashboardWindowReopen()
    let deadline = Date().addingTimeInterval(timeout)
    repeat {
        if let windowID = visibleDashboardWindowID() {
            Thread.sleep(forTimeInterval: 0.2)
            return windowID
        }
        Thread.sleep(forTimeInterval: 0.1)
    } while Date() < deadline
    return nil
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
        if let targetProcessIdentifier {
            let ownerPID = (info[kCGWindowOwnerPID as String] as? NSNumber)?.int32Value
            guard ownerPID == targetProcessIdentifier else { return nil }
        }
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

private func waitForElementCount(
    identifier: String,
    expectedCount: Int,
    in root: AXUIElement,
    timeout: TimeInterval
) -> Bool {
    let deadline = Date().addingTimeInterval(timeout)
    var stableSamples = 0
    repeat {
        let count = countElements(
            in: root,
            maxDepth: 32,
            maxNodes: 35_000,
            where: {
                identifierMatches(
                    stringAttribute($0, "AXIdentifier" as CFString),
                    expected: identifier
                )
            }
        )
        if count == expectedCount {
            stableSamples += 1
            if stableSamples >= 2 {
                return true
            }
        } else {
            stableSamples = 0
        }
        Thread.sleep(forTimeInterval: 0.10)
    } while Date() < deadline
    return false
}

private func waitForStableWorkspaceContent(
    rootIdentifier: String,
    layoutMode: String? = nil,
    in appElement: AXUIElement
) -> Bool {
    let deadline = Date().addingTimeInterval(timeout)
    var previousSignature: String?
    var stableSamples = 0
    repeat {
        let layoutReady = layoutMode.map { mode in
            waitForElement(
                withIdentifier: "workspace-layout-mode-\(mode)",
                in: appElement,
                timeout: 0.10
            ) != nil
        } ?? true
        if layoutReady,
           hasVisibleDashboardWindow(),
           hasUsableAccessibilityWindow(in: appElement),
           let root = waitForElement(
               withIdentifier: rootIdentifier,
               in: appElement,
               timeout: 0.10
           ),
           let frame = accessibilityFrameIncludingDescendants(of: root),
           isMeaningful(frame) {
            let signature = "\(Int(frame.minX.rounded())),\(Int(frame.minY.rounded())),"
                + "\(Int(frame.width.rounded())),\(Int(frame.height.rounded()))"
            if signature == previousSignature {
                stableSamples += 1
                if stableSamples >= 2 {
                    return true
                }
            } else {
                previousSignature = signature
                stableSamples = 1
            }
        } else {
            previousSignature = nil
            stableSamples = 0
        }
        Thread.sleep(forTimeInterval: 0.10)
    } while Date() < deadline
    return false
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

private func waitForElementAbsence(
    identifiers: [String],
    in root: AXUIElement,
    timeout: TimeInterval
) -> Bool {
    let deadline = Date().addingTimeInterval(timeout)
    repeat {
        let hasVisibleIdentifier = identifiers.contains { identifier in
            waitForElement(withIdentifier: identifier, in: root, timeout: 0.05) != nil
        }
        if !hasVisibleIdentifier {
            return true
        }
        Thread.sleep(forTimeInterval: 0.05)
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
           waitForElement(withIdentifier: "workspace-content-root-\(rawValue)", in: root, timeout: 0.1) != nil {
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
    var stack: [(AXUIElement, Int)] = [(refreshedApplicationRoot(ifNeeded: root), 0)]
    var visited = Set<AXUIElement>()
    var visitedCount = 0

    while let (element, depth) = stack.popLast() {
        guard visited.insert(element).inserted else {
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

private func countElements(
    in root: AXUIElement,
    maxDepth: Int,
    maxNodes: Int,
    where predicate: (AXUIElement) -> Bool
) -> Int {
    var stack: [(AXUIElement, Int)] = [(refreshedApplicationRoot(ifNeeded: root), 0)]
    var visited = Set<AXUIElement>()
    var visitedCount = 0
    var matches = 0

    while let (element, depth) = stack.popLast() {
        guard visited.insert(element).inserted else {
            continue
        }

        visitedCount += 1
        guard visitedCount <= maxNodes else {
            return matches
        }

        if predicate(element) {
            matches += 1
        }

        guard depth < maxDepth else {
            continue
        }

        for child in childElements(of: element).reversed() {
            stack.append((child, depth + 1))
        }
    }

    return matches
}

private func findIdentifiers(
    _ identifiers: Set<String>,
    in root: AXUIElement,
    maxDepth: Int,
    maxNodes: Int
) -> Set<String> {
    var remaining = identifiers
    var found = Set<String>()
    var stack: [(AXUIElement, Int)] = [(refreshedApplicationRoot(ifNeeded: root), 0)]
    var visited = Set<AXUIElement>()
    var visitedCount = 0

    while let (element, depth) = stack.popLast() {
        guard visited.insert(element).inserted else {
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

private func refreshedApplicationRoot(ifNeeded root: AXUIElement) -> AXUIElement {
    guard let targetProcessIdentifier else {
        return root
    }
    if let app = NSRunningApplication(processIdentifier: targetProcessIdentifier),
       !app.isTerminated,
       !app.isActive {
        app.unhide()
        app.activate(options: [.activateAllWindows])
    }
    let currentRoot = AXUIElementCreateApplication(targetProcessIdentifier)
    AXUIElementSetAttributeValue(currentRoot, kAXFrontmostAttribute as CFString, kCFBooleanTrue)
    return CFEqual(root, currentRoot) ? currentRoot : root
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
