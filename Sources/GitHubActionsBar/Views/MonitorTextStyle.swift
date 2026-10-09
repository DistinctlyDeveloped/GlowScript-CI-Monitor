import SwiftUI

/// Opaque metadata colors avoid the extra vibrancy/opacity attenuation of
/// hierarchical secondary and tertiary styles over the monitor's glass panel.
/// Resolve from SwiftUI's environment so appearance and Increase Contrast
/// changes are honored, including when a view overrides its color scheme.
struct MonitorTextStyle: ShapeStyle {
    enum Role { case secondary, tertiary }
    let role: Role

    static let secondary = MonitorTextStyle(role: .secondary)
    static let tertiary = MonitorTextStyle(role: .tertiary)

    func resolve(in environment: EnvironmentValues) -> Color {
        color(scheme: environment.colorScheme, contrast: environment.colorSchemeContrast)
    }

    func color(scheme: ColorScheme, contrast: ColorSchemeContrast) -> Color {
        let dark = scheme == .dark
        let increased = contrast == .increased
        let component: Double
        switch (role, dark, increased) {
        case (.secondary, false, false): component = 80
        case (.tertiary, false, false): component = 88
        case (.secondary, true, false): component = 208
        case (.tertiary, true, false): component = 192
        case (.secondary, false, true): component = 48
        case (.tertiary, false, true): component = 56
        case (.secondary, true, true): component = 221
        case (.tertiary, true, true): component = 204
        }
        return Color(.sRGB, red: component / 255, green: component / 255,
                     blue: component / 255, opacity: 1)
    }
}

extension ShapeStyle where Self == MonitorTextStyle {
    static var monitorSecondary: MonitorTextStyle { .secondary }
    static var monitorTertiary: MonitorTextStyle { .tertiary }
}
