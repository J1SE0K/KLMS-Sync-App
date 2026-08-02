#!/usr/bin/env swift

import AppKit
import ApplicationServices
import Foundation

private enum ResizeProbeError: Error, CustomStringConvertible {
    case accessibilityPermissionMissing
    case appNotRunning
    case attribute(String)
    case eventCreationFailed
    case appNotFrontmost(String)
    case resizeFailed(offset: CGFloat, before: CGSize, after: CGSize)

    var description: String {
        switch self {
        case .accessibilityPermissionMissing:
            "Accessibility permission is missing."
        case .appNotRunning:
            "KLMS Sync is not running."
        case let .attribute(name):
            "Accessibility attribute failed: \(name)"
        case .eventCreationFailed:
            "Could not create a mouse event."
        case let .appNotFrontmost(name):
            "KLMS Sync is not frontmost (frontmost: \(name))."
        case let .resizeFailed(offset, before, after):
            "Mouse resize failed at \(Int(offset))pt inside the edge: \(before) -> \(after)"
        }
    }
}

private let bundleID = ProcessInfo.processInfo.environment["KLMS_MAC_BUNDLE_ID"] ?? "com.local.KLMSync"
private let appPath = ProcessInfo.processInfo.environment["KLMS_MAC_APP_PATH"]?
    .trimmingCharacters(in: .whitespacesAndNewlines)

do {
    try runProbe()
} catch {
    FileHandle.standardError.write(Data("resize smoke failed: \(error)\n".utf8))
    exit(1)
}

private func runProbe() throws {
    let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: false] as CFDictionary
    guard AXIsProcessTrustedWithOptions(options) else {
        throw ResizeProbeError.accessibilityPermissionMissing
    }
    guard let app = runningApplication() else {
        throw ResizeProbeError.appNotRunning
    }

    let appElement = AXUIElementCreateApplication(app.processIdentifier)
    let window = unsafeBitCast(
        try copyValue(appElement, kAXMainWindowAttribute as CFString),
        to: AXUIElement.self
    )
    guard waitUntilFrontmost(app: app, appElement: appElement, window: window) else {
        throw ResizeProbeError.appNotFrontmost(
            NSWorkspace.shared.frontmostApplication?.localizedName ?? "unknown"
        )
    }

    let originalPosition = try pointValue(window, kAXPositionAttribute as CFString)
    let originalSize = try sizeValue(window, kAXSizeAttribute as CFString)
    defer {
        try? setPoint(originalPosition, on: window, attribute: kAXPositionAttribute as CFString)
        try? setSize(originalSize, on: window, attribute: kAXSizeAttribute as CFString)
    }

    for offset in [CGFloat(2), 10, 15.5] {
        try setPoint(CGPoint(x: 120, y: 120), on: window, attribute: kAXPositionAttribute as CFString)
        try setSize(CGSize(width: 900, height: 650), on: window, attribute: kAXSizeAttribute as CFString)
        Thread.sleep(forTimeInterval: 0.35)
        guard waitUntilFrontmost(app: app, appElement: appElement, window: window) else {
            throw ResizeProbeError.appNotFrontmost(
                NSWorkspace.shared.frontmostApplication?.localizedName ?? "unknown"
            )
        }
        let position = try pointValue(window, kAXPositionAttribute as CFString)
        let before = try sizeValue(window, kAXSizeAttribute as CFString)
        let start = CGPoint(
            x: position.x + before.width - offset,
            y: position.y + before.height / 2
        )
        try dragMouse(from: start, horizontalDistance: 80)
        Thread.sleep(forTimeInterval: 0.45)
        let afterPosition = try pointValue(window, kAXPositionAttribute as CFString)
        let after = try sizeValue(window, kAXSizeAttribute as CFString)
        guard after.width >= before.width + 60,
              abs(after.height - before.height) <= 3,
              abs(afterPosition.x - position.x) <= 3 else {
            throw ResizeProbeError.resizeFailed(offset: offset, before: before, after: after)
        }
    }

    print("ok: installed Mac app resizes from the native edge and the expanded 16pt inner hit area")
}

private func waitUntilFrontmost(
    app: NSRunningApplication,
    appElement: AXUIElement,
    window: AXUIElement
) -> Bool {
    let deadline = Date().addingTimeInterval(3.0)
    var frontmostStableSince: Date?
    repeat {
        app.unhide()
        app.activate(options: [.activateAllWindows])
        AXUIElementSetAttributeValue(appElement, kAXFrontmostAttribute as CFString, kCFBooleanTrue)
        AXUIElementPerformAction(window, kAXRaiseAction as CFString)
        if NSWorkspace.shared.frontmostApplication?.processIdentifier == app.processIdentifier {
            let now = Date()
            if let frontmostStableSince,
               now.timeIntervalSince(frontmostStableSince) >= 0.25 {
                return true
            } else if frontmostStableSince == nil {
                frontmostStableSince = now
            }
        } else {
            frontmostStableSince = nil
        }
        Thread.sleep(forTimeInterval: 0.05)
    } while Date() < deadline
    return false
}

private func runningApplication() -> NSRunningApplication? {
    if let appPath {
        let bundlePath = URL(fileURLWithPath: appPath)
            .resolvingSymlinksInPath()
            .standardizedFileURL.path
        return NSWorkspace.shared.runningApplications.first(where: { app in
            guard !app.isTerminated,
                  let executablePath = app.executableURL?.resolvingSymlinksInPath().standardizedFileURL.path else {
                return false
            }
            return executablePath.hasPrefix(bundlePath + "/Contents/MacOS/")
        })
    }
    return NSRunningApplication.runningApplications(withBundleIdentifier: bundleID)
        .first(where: { !$0.isTerminated })
}

private func dragMouse(from start: CGPoint, horizontalDistance: CGFloat) throws {
    guard let source = CGEventSource(stateID: .hidSystemState) else {
        throw ResizeProbeError.eventCreationFailed
    }
    try postMouseEvent(.mouseMoved, at: start, source: source)
    Thread.sleep(forTimeInterval: 0.10)
    try postMouseEvent(.leftMouseDown, at: start, source: source)
    for step in 1...8 {
        let fraction = CGFloat(step) / 8
        try postMouseEvent(
            .leftMouseDragged,
            at: CGPoint(x: start.x + horizontalDistance * fraction, y: start.y),
            source: source
        )
        usleep(30_000)
    }
    try postMouseEvent(
        .leftMouseUp,
        at: CGPoint(x: start.x + horizontalDistance, y: start.y),
        source: source
    )
}

private func postMouseEvent(_ type: CGEventType, at point: CGPoint, source: CGEventSource) throws {
    guard let event = CGEvent(
        mouseEventSource: source,
        mouseType: type,
        mouseCursorPosition: point,
        mouseButton: .left
    ) else {
        throw ResizeProbeError.eventCreationFailed
    }
    event.post(tap: .cghidEventTap)
}

private func copyValue(_ element: AXUIElement, _ attribute: CFString) throws -> CFTypeRef {
    var value: CFTypeRef?
    guard AXUIElementCopyAttributeValue(element, attribute, &value) == .success,
          let value else {
        throw ResizeProbeError.attribute(attribute as String)
    }
    return value
}

private func pointValue(_ element: AXUIElement, _ attribute: CFString) throws -> CGPoint {
    let raw = try copyValue(element, attribute)
    var value = CGPoint.zero
    guard CFGetTypeID(raw) == AXValueGetTypeID(),
          AXValueGetValue(raw as! AXValue, .cgPoint, &value) else {
        throw ResizeProbeError.attribute(attribute as String)
    }
    return value
}

private func sizeValue(_ element: AXUIElement, _ attribute: CFString) throws -> CGSize {
    let raw = try copyValue(element, attribute)
    var value = CGSize.zero
    guard CFGetTypeID(raw) == AXValueGetTypeID(),
          AXValueGetValue(raw as! AXValue, .cgSize, &value) else {
        throw ResizeProbeError.attribute(attribute as String)
    }
    return value
}

private func setPoint(_ point: CGPoint, on element: AXUIElement, attribute: CFString) throws {
    var point = point
    guard let value = AXValueCreate(.cgPoint, &point),
          AXUIElementSetAttributeValue(element, attribute, value) == .success else {
        throw ResizeProbeError.attribute(attribute as String)
    }
}

private func setSize(_ size: CGSize, on element: AXUIElement, attribute: CFString) throws {
    var size = size
    guard let value = AXValueCreate(.cgSize, &size),
          AXUIElementSetAttributeValue(element, attribute, value) == .success else {
        throw ResizeProbeError.attribute(attribute as String)
    }
}
