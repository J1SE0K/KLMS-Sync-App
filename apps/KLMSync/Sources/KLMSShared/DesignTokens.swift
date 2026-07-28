import CoreGraphics

public enum KLMSSpacing {
    public static let optical: CGFloat = 1
    public static let hairline: CGFloat = 2
    public static let micro: CGFloat = 3
    public static let tight: CGFloat = 4
    public static let snug: CGFloat = 5
    public static let compact: CGFloat = 6
    public static let compactControl: CGFloat = 7
    public static let standard: CGFloat = 8
    public static let standardControl: CGFloat = 9
    public static let comfortable: CGFloat = 10
    public static let comfortableControl: CGFloat = 11
    public static let section: CGFloat = 12
    public static let cardInset: CGFloat = 13
    public static let roomy: CGFloat = 14
    public static let roomyControl: CGFloat = 15
    public static let spacious: CGFloat = 16
    public static let workstationColumn: CGFloat = 18
    public static let compactScreenInset: CGFloat = 20
    public static let screenInset: CGFloat = 24
}

public enum KLMSRadius {
    public static let indicator: CGFloat = 2
    public static let compactSurface: CGFloat = 6
    public static let compactControl: CGFloat = 7
    public static let smallSurface: CGFloat = 8
    public static let standardSurface: CGFloat = 9
    public static let control: CGFloat = 10
    public static let elevatedControl: CGFloat = 11
    public static let card: CGFloat = 12
    public static let prominentCard: CGFloat = 13
    public static let panel: CGFloat = 14
    public static let largePanel: CGFloat = 16
    public static let featurePanel: CGFloat = 18
}

public enum KLMSTypeSize {
    public static let microIndicator: CGFloat = 4
    public static let compactStatus: CGFloat = 9
    public static let badge: CGFloat = 10
    public static let footnoteBadge: CGFloat = 11
    public static let control: CGFloat = 13
    public static let sectionIcon: CGFloat = 20
    public static let onboardingTitle: CGFloat = 24
    public static let metric: CGFloat = 26
    public static let prominentMetric: CGFloat = 28
    public static let statusIcon: CGFloat = 30
    public static let heroMetric: CGFloat = 34
}

public enum KLMSControlSize {
    public static let minimumInteractive: CGFloat = 44
}
