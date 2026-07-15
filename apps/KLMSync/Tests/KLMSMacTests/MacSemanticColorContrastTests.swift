import AppKit
import SwiftUI
import XCTest
@testable import KLMSMac

@MainActor
final class MacSemanticColorContrastTests: XCTestCase {
    func testSemanticStatusForegroundsMeetAAOnPaperGraphiteSurfaces() throws {
        let appearances: [NSAppearance.Name] = [.aqua, .darkAqua]
        let cases: [(String, Color, [Color])] = [
            (
                "warning",
                .klmsMacWarningForeground,
                [.klmsMacCardBackground, .klmsMacSubtleCardBackground, .klmsMacWarningBackground]
            ),
            (
                "success",
                .klmsMacSuccessForeground,
                [.klmsMacCardBackground, .klmsMacSubtleCardBackground, .klmsMacSuccessBackground]
            ),
            (
                "danger",
                .klmsMacDangerForeground,
                [.klmsMacCardBackground, .klmsMacSubtleCardBackground, .klmsMacDangerBackground]
            ),
        ]

        for appearanceName in appearances {
            for (name, foreground, backgrounds) in cases {
                let resolvedForeground = try resolvedRGB(foreground, appearanceName: appearanceName)
                for background in backgrounds {
                    let resolvedBackground = try resolvedRGB(background, appearanceName: appearanceName)
                    XCTAssertGreaterThanOrEqual(
                        contrastRatio(resolvedForeground, resolvedBackground),
                        4.5,
                        "\(name) foreground does not meet WCAG AA in \(appearanceName.rawValue)."
                    )
                }
            }
        }
    }

    private func resolvedRGB(
        _ color: Color,
        appearanceName: NSAppearance.Name
    ) throws -> (red: Double, green: Double, blue: Double) {
        guard let appearance = NSAppearance(named: appearanceName) else {
            throw ContrastTestError.unavailableAppearance
        }
        var resolvedColor: NSColor?
        appearance.performAsCurrentDrawingAppearance {
            resolvedColor = NSColor(color).usingColorSpace(.sRGB)
        }
        guard let resolvedColor else {
            throw ContrastTestError.unresolvedColor
        }
        return (
            Double(resolvedColor.redComponent),
            Double(resolvedColor.greenComponent),
            Double(resolvedColor.blueComponent)
        )
    }

    private func contrastRatio(
        _ first: (red: Double, green: Double, blue: Double),
        _ second: (red: Double, green: Double, blue: Double)
    ) -> Double {
        let firstLuminance = relativeLuminance(first)
        let secondLuminance = relativeLuminance(second)
        let lighter = max(firstLuminance, secondLuminance)
        let darker = min(firstLuminance, secondLuminance)
        return (lighter + 0.05) / (darker + 0.05)
    }

    private func relativeLuminance(
        _ color: (red: Double, green: Double, blue: Double)
    ) -> Double {
        let red = linearComponent(color.red)
        let green = linearComponent(color.green)
        let blue = linearComponent(color.blue)
        return (0.2126 * red) + (0.7152 * green) + (0.0722 * blue)
    }

    private func linearComponent(_ component: Double) -> Double {
        component <= 0.04045
            ? component / 12.92
            : pow((component + 0.055) / 1.055, 2.4)
    }
}

private enum ContrastTestError: Error {
    case unavailableAppearance
    case unresolvedColor
}
