import Foundation
import XCTest

final class IOSAccessibilityDesignTests: XCTestCase {
    private struct RGB {
        var red: Double
        var green: Double
        var blue: Double
    }

    func testSemanticStatusForegroundsMeetWCAGAAInLightAndDarkAppearances() throws {
        let source = try iosSource()
        let pairs = [
            ("warning", "klmsWarningForeground", "klmsWarningBackground"),
            ("danger", "klmsDangerForeground", "klmsDangerBackground"),
            ("success", "klmsSuccessForeground", "klmsSuccessBackground"),
        ]

        for (name, foregroundToken, backgroundToken) in pairs {
            let foregrounds = try uiKitColors(for: foregroundToken, in: source)
            let backgrounds = try uiKitColors(for: backgroundToken, in: source)
            XCTAssertEqual(foregrounds.count, 2, "Expected light and dark UIKit values for \(foregroundToken).")
            XCTAssertEqual(backgrounds.count, 2, "Expected light and dark UIKit values for \(backgroundToken).")

            for index in 0..<min(foregrounds.count, backgrounds.count) {
                let appearance = index == 0 ? "light" : "dark"
                XCTAssertGreaterThanOrEqual(
                    contrastRatio(foregrounds[index], backgrounds[index]),
                    4.5,
                    "\(name) \(appearance) status foreground must meet WCAG AA against its paired background."
                )
            }
        }
    }

    func testSmallIOSStatusCopyDoesNotUseBorderTokensAsForegrounds() throws {
        let source = try iosSource()
        XCTAssertNil(
            source.range(
                of: #"foregroundStyle\([^\n]*klms(?:Warning|Danger|Success)Border"#,
                options: .regularExpression
            ),
            "Border tokens are intentionally softer; small status text and icons must use semantic foreground tokens."
        )
        XCTAssertNil(
            source.range(
                of: #"\btint:\s*[^\n]*klms(?:Warning|Danger|Success)Border"#,
                options: .regularExpression
            ),
            "Values passed into visible tint parameters must use semantic foreground tokens."
        )

        for (name, body) in try visibleColorAccessorBodies(in: source) {
            XCTAssertNil(
                body.range(
                    of: #"klms(?:Warning|Danger|Success)Border"#,
                    options: .regularExpression
                ),
                "Visible color accessor \(name) must not return a border token."
            )
        }
    }

    func testCoreIOSTypographyUsesDynamicTypeStyles() throws {
        let source = try iosSource()
        XCTAssertNil(
            source.range(of: #"\.font\(\.system\(size:"#, options: .regularExpression),
            "Fixed point fonts bypass Dynamic Type and must not return to iOS navigation, sync, or status UI."
        )
        XCTAssertTrue(source.contains("@Environment(\\.dynamicTypeSize)"))
        XCTAssertTrue(source.contains("dynamicTypeSize.isAccessibilitySize"))
    }

    private func uiKitColors(for token: String, in source: String) throws -> [RGB] {
        let marker = "static var \(token): Color {"
        guard let start = source.range(of: marker),
              let end = source[start.upperBound...].range(of: "\n    }\n") else {
            XCTFail("Missing semantic color token \(token).")
            return []
        }
        let block = String(source[start.lowerBound..<end.upperBound])
        let expression = try NSRegularExpression(
            pattern: #"UIColor\(red:\s*([0-9.]+),\s*green:\s*([0-9.]+),\s*blue:\s*([0-9.]+),\s*alpha:\s*[0-9.]+\)"#
        )
        let range = NSRange(block.startIndex..<block.endIndex, in: block)
        return expression.matches(in: block, range: range).compactMap { match in
            guard let redRange = Range(match.range(at: 1), in: block),
                  let greenRange = Range(match.range(at: 2), in: block),
                  let blueRange = Range(match.range(at: 3), in: block),
                  let red = Double(block[redRange]),
                  let green = Double(block[greenRange]),
                  let blue = Double(block[blueRange]) else {
                return nil
            }
            return RGB(red: red, green: green, blue: blue)
        }
    }

    private func visibleColorAccessorBodies(in source: String) throws -> [(String, String)] {
        let expression = try NSRegularExpression(
            pattern: #"(?m)(?:private\s+)?(?:static\s+)?(?:var|func)\s+([A-Za-z_][A-Za-z0-9_]*)[^\n{]*\{"#
        )
        let excludedAccessors = Set([
            "activeShadowColor",
            "colorScheme",
            "klmsAdaptiveColor",
            "klmsAppKitAdaptiveColor",
        ])
        let range = NSRange(source.startIndex..<source.endIndex, in: source)

        return expression.matches(in: source, range: range).compactMap { match in
            guard let nameRange = Range(match.range(at: 1), in: source),
                  let declarationRange = Range(match.range, in: source) else {
                return nil
            }
            let name = String(source[nameRange])
            let normalizedName = name.lowercased()
            guard !excludedAccessors.contains(name),
                  normalizedName.contains("tint") || normalizedName.hasSuffix("color"),
                  let openingBrace = source[declarationRange].lastIndex(of: "{"),
                  let body = balancedBlock(in: source, openingAt: openingBrace) else {
                return nil
            }
            return (name, body)
        }
    }

    private func balancedBlock(in source: String, openingAt openingBrace: String.Index) -> String? {
        var depth = 0
        var index = openingBrace
        while index < source.endIndex {
            switch source[index] {
            case "{":
                depth += 1
            case "}":
                depth -= 1
                if depth == 0 {
                    return String(source[openingBrace...index])
                }
            default:
                break
            }
            index = source.index(after: index)
        }
        return nil
    }

    private func contrastRatio(_ lhs: RGB, _ rhs: RGB) -> Double {
        let brighter = max(relativeLuminance(lhs), relativeLuminance(rhs))
        let darker = min(relativeLuminance(lhs), relativeLuminance(rhs))
        return (brighter + 0.05) / (darker + 0.05)
    }

    private func relativeLuminance(_ color: RGB) -> Double {
        0.2126 * linearized(color.red)
            + 0.7152 * linearized(color.green)
            + 0.0722 * linearized(color.blue)
    }

    private func linearized(_ component: Double) -> Double {
        component <= 0.04045
            ? component / 12.92
            : pow((component + 0.055) / 1.055, 2.4)
    }

    private func iosSource() throws -> String {
        try String(
            contentsOf: packageRoot().appendingPathComponent("Sources/KLMSiOS/KLMSiOSApp.swift"),
            encoding: .utf8
        )
    }

    private func packageRoot() -> URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
    }
}
