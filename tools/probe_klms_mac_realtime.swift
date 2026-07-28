#!/usr/bin/env swift

import AppKit
import ApplicationServices
import Foundation

private enum ProbeFailure: Error, CustomStringConvertible {
    case invalidArguments
    case accessibilityPermissionMissing
    case appNotRunning(pid_t)
    case dashboardUnavailable
    case workspaceUnavailable(String)
    case workspacePressFailed(String, AXError)
    case expectedTextMissing(String)

    var description: String {
        switch self {
        case .invalidArguments:
            return "usage: probe_klms_mac_realtime.swift --pid <pid> [--navigate <workspace>] [--expected <text> --started-at-ms <epoch-ms>]"
        case .accessibilityPermissionMissing:
            return "Accessibility permission is not granted for Codex/Terminal."
        case let .appNotRunning(pid):
            return "The isolated KLMS QA app is not running at pid \(pid)."
        case .dashboardUnavailable:
            return "The isolated KLMS QA dashboard did not become accessible."
        case let .workspaceUnavailable(identifier):
            return "The isolated KLMS QA workspace is unavailable: \(identifier)."
        case let .workspacePressFailed(identifier, error):
            return "Could not select isolated KLMS QA workspace \(identifier): \(error)."
        case let .expectedTextMissing(text):
            return "Expected isolated KLMS QA text did not become visible: \(text)."
        }
    }
}

private struct Arguments {
    var pid: pid_t
    var workspace: String?
    var expectedText: String?
    var startedAtMilliseconds: Double?
    var timeout: TimeInterval

    init(commandLine: [String]) throws {
        var pidValue: pid_t?
        var workspaceValue: String?
        var expectedValue: String?
        var startedAtValue: Double?
        var timeoutValue: TimeInterval = 8
        var index = 1
        while index < commandLine.count {
            switch commandLine[index] {
            case "--pid":
                index += 1
                guard index < commandLine.count, let value = Int32(commandLine[index]), value > 0 else {
                    throw ProbeFailure.invalidArguments
                }
                pidValue = value
            case "--navigate":
                index += 1
                guard index < commandLine.count, !commandLine[index].isEmpty else {
                    throw ProbeFailure.invalidArguments
                }
                workspaceValue = commandLine[index]
            case "--expected":
                index += 1
                guard index < commandLine.count, !commandLine[index].isEmpty else {
                    throw ProbeFailure.invalidArguments
                }
                expectedValue = commandLine[index]
            case "--started-at-ms":
                index += 1
                guard index < commandLine.count, let value = Double(commandLine[index]), value > 0 else {
                    throw ProbeFailure.invalidArguments
                }
                startedAtValue = value
            case "--timeout":
                index += 1
                guard index < commandLine.count,
                      let value = TimeInterval(commandLine[index]),
                      value > 0,
                      value <= 30 else {
                    throw ProbeFailure.invalidArguments
                }
                timeoutValue = value
            default:
                throw ProbeFailure.invalidArguments
            }
            index += 1
        }
        guard let pidValue,
              (expectedValue == nil) == (startedAtValue == nil),
              expectedValue != nil || workspaceValue != nil else {
            throw ProbeFailure.invalidArguments
        }
        pid = pidValue
        workspace = workspaceValue
        expectedText = expectedValue
        startedAtMilliseconds = startedAtValue
        timeout = timeoutValue
    }
}

do {
    let arguments = try Arguments(commandLine: CommandLine.arguments)
    try runProbe(arguments)
} catch {
    FileHandle.standardError.write(Data("isolated realtime probe failed: \(error)\n".utf8))
    exit(1)
}

private func runProbe(_ arguments: Arguments) throws {
    guard let app = NSRunningApplication(processIdentifier: arguments.pid), !app.isTerminated else {
        throw ProbeFailure.appNotRunning(arguments.pid)
    }

    let trustedOptions = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: false] as CFDictionary
    guard AXIsProcessTrustedWithOptions(trustedOptions) else {
        throw ProbeFailure.accessibilityPermissionMissing
    }

    app.unhide()
    app.activate(options: [.activateAllWindows])
    let appElement = AXUIElementCreateApplication(arguments.pid)
    AXUIElementSetAttributeValue(appElement, kAXFrontmostAttribute as CFString, kCFBooleanTrue)
    guard waitForElement(
        identifier: "klms-dashboard-root",
        in: appElement,
        timeout: arguments.timeout
    ) != nil else {
        throw ProbeFailure.dashboardUnavailable
    }

    if let workspace = arguments.workspace {
        let identifier = "workspace-\(workspace)"
        guard let button = waitForElement(
            identifier: identifier,
            in: appElement,
            timeout: arguments.timeout
        ) else {
            throw ProbeFailure.workspaceUnavailable(identifier)
        }
        let error = AXUIElementPerformAction(button, kAXPressAction as CFString)
        guard error == .success else {
            throw ProbeFailure.workspacePressFailed(identifier, error)
        }
    }

    guard let expectedText = arguments.expectedText,
          let startedAtMilliseconds = arguments.startedAtMilliseconds else {
        emitJSON(["ok": true])
        return
    }
    let deadline = Date().addingTimeInterval(arguments.timeout)
    var visitedNodes = 0
    repeat {
        var nodes = 0
        if treeContainsText(expectedText, in: appElement, visitedNodes: &nodes) {
            visitedNodes = nodes
            let observedAt = Date().timeIntervalSince1970 * 1_000
            emitJSON([
                "ok": true,
                "expectedText": expectedText,
                "observedAtEpochMs": observedAt,
                "elapsedMs": max(0, observedAt - startedAtMilliseconds),
                "visitedNodes": visitedNodes,
            ])
            return
        }
        visitedNodes = max(visitedNodes, nodes)
        Thread.sleep(forTimeInterval: 0.02)
    } while Date() < deadline
    FileHandle.standardError.write(Data("visited accessibility nodes: \(visitedNodes)\n".utf8))
    throw ProbeFailure.expectedTextMissing(expectedText)
}

private func waitForElement(
    identifier: String,
    in root: AXUIElement,
    timeout: TimeInterval
) -> AXUIElement? {
    let deadline = Date().addingTimeInterval(timeout)
    repeat {
        if let match = findElement(identifier: identifier, in: root) {
            return match
        }
        Thread.sleep(forTimeInterval: 0.03)
    } while Date() < deadline
    return nil
}

private func findElement(identifier: String, in root: AXUIElement) -> AXUIElement? {
    var stack: [(AXUIElement, Int)] = [(root, 0)]
    var visited = Set<CFHashCode>()
    var count = 0
    while let (element, depth) = stack.popLast(), count < 40_000 {
        let hash = CFHash(element)
        guard visited.insert(hash).inserted else { continue }
        count += 1
        if stringAttribute(element, kAXIdentifierAttribute as CFString) == identifier {
            return element
        }
        guard depth < 36 else { continue }
        for child in childElements(of: element).reversed() {
            stack.append((child, depth + 1))
        }
    }
    return nil
}

private func treeContainsText(
    _ expectedText: String,
    in root: AXUIElement,
    visitedNodes: inout Int
) -> Bool {
    var stack: [(AXUIElement, Int)] = [(root, 0)]
    var visited = Set<CFHashCode>()
    while let (element, depth) = stack.popLast(), visitedNodes < 40_000 {
        let hash = CFHash(element)
        guard visited.insert(hash).inserted else { continue }
        visitedNodes += 1
        for attribute in [
            kAXTitleAttribute,
            kAXValueAttribute,
            kAXDescriptionAttribute,
            kAXHelpAttribute,
        ] {
            if let value = stringAttribute(element, attribute as CFString),
               value.localizedStandardContains(expectedText) {
                return true
            }
        }
        guard depth < 36 else { continue }
        for child in childElements(of: element).reversed() {
            stack.append((child, depth + 1))
        }
    }
    return false
}

private func childElements(of element: AXUIElement) -> [AXUIElement] {
    var value: CFTypeRef?
    guard AXUIElementCopyAttributeValue(
        element,
        kAXChildrenAttribute as CFString,
        &value
    ) == .success else {
        return []
    }
    return value as? [AXUIElement] ?? []
}

private func stringAttribute(_ element: AXUIElement, _ attribute: CFString) -> String? {
    var value: CFTypeRef?
    guard AXUIElementCopyAttributeValue(element, attribute, &value) == .success else {
        return nil
    }
    if let string = value as? String {
        return string
    }
    if let attributed = value as? NSAttributedString {
        return attributed.string
    }
    return nil
}

private func emitJSON(_ payload: [String: Any]) {
    guard let data = try? JSONSerialization.data(withJSONObject: payload, options: [.sortedKeys]),
          let text = String(data: data, encoding: .utf8) else {
        return
    }
    print(text)
}
