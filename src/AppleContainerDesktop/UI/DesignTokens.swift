import AppKit

enum AppColors {
    static let background = dynamic(light: rgb(0.9850, 0.9870, 0.9910), dark: rgb(0.0700, 0.0780, 0.0900))
    static let surface = dynamic(light: rgb(1.0000, 1.0000, 1.0000), dark: rgb(0.1050, 0.1150, 0.1320))
    static let sidebar = dynamic(light: rgb(0.9480, 0.9560, 0.9710), dark: rgb(0.0830, 0.0920, 0.1080))
    static let border = dynamic(light: rgb(0.8350, 0.8500, 0.8750), dark: rgb(0.2200, 0.2350, 0.2600))
    static let ink = dynamic(light: rgb(0.0808, 0.1006, 0.1328), dark: rgb(0.8962, 0.9027, 0.9131))
    static let muted = dynamic(light: rgb(0.3546, 0.3737, 0.4045), dark: rgb(0.6600, 0.6800, 0.7200))
    static let primary = dynamic(light: rgb(0.7206, 0.5018, 0.0648), dark: rgb(0.8099, 0.6036, 0.2656))
    static let primarySoft = dynamic(light: rgb(0.9831, 0.9113, 0.8081), dark: rgb(0.1788, 0.1193, 0.0208))
    static let success = dynamic(light: rgb(0.1743, 0.5167, 0.2776), dark: rgb(0.3754, 0.6905, 0.4504))
    static let warning = dynamic(light: rgb(0.7842, 0.5620, 0.1670), dark: rgb(0.8616, 0.6529, 0.3183))
    static let danger = dynamic(light: rgb(0.7623, 0.2619, 0.2232), dark: rgb(0.9067, 0.4557, 0.4050))
    static let info = dynamic(light: rgb(0.2023, 0.4357, 0.6613), dark: rgb(0.4390, 0.6516, 0.8696))

    private static func rgb(_ red: CGFloat, _ green: CGFloat, _ blue: CGFloat) -> NSColor {
        NSColor(srgbRed: red, green: green, blue: blue, alpha: 1)
    }

    private static func dynamic(light: NSColor, dark: NSColor) -> NSColor {
        NSColor(name: nil) { appearance in
            if appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua {
                return dark
            }
            return light
        }
    }
}

enum AppFonts {
    static var title: NSFont { NSFont.systemFont(ofSize: 26, weight: .semibold) }
    static var heading: NSFont { NSFont.systemFont(ofSize: 17, weight: .semibold) }
    static var body: NSFont { NSFont.systemFont(ofSize: 13) }
    static var small: NSFont { NSFont.systemFont(ofSize: 12) }
    static var sidebar: NSFont { NSFont.systemFont(ofSize: 13, weight: .medium) }
    static var mono: NSFont { NSFont.monospacedSystemFont(ofSize: 12, weight: .regular) }
}

enum AppSpacing {
    static let xs: CGFloat = 4
    static let sm: CGFloat = 8
    static let md: CGFloat = 12
    static let lg: CGFloat = 16
    static let xl: CGFloat = 24
    static let xxl: CGFloat = 32
}
