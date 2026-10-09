import SwiftUI
import Testing
@testable import Octowatch

struct MonitorTextStyleTests {
    @Test func metadataRemainsOpaqueAndOrderedInEveryAppearance() {
        for scheme in [ColorScheme.light, .dark] {
            for contrast in [ColorSchemeContrast.standard, .increased] {
                var environment = EnvironmentValues()
                environment.colorScheme = scheme
                let secondary = MonitorTextStyle.secondary.color(scheme: scheme, contrast: contrast).resolve(in: environment)
                let tertiary = MonitorTextStyle.tertiary.color(scheme: scheme, contrast: contrast).resolve(in: environment)
                #expect(secondary.opacity == 1 && tertiary.opacity == 1)
                #expect(secondary.red == secondary.green && secondary.green == secondary.blue)
                #expect(tertiary.red == tertiary.green && tertiary.green == tertiary.blue)
                if scheme == .light {
                    #expect(secondary.red > 0 && secondary.red < tertiary.red)
                } else {
                    #expect(secondary.red < 1 && secondary.red > tertiary.red)
                }
            }
        }
    }

    @Test func metadataMeetsContrastOnCapturedDashboardSurfaces() {
        // sRGB backgrounds sampled from the native dashboard's host cards.
        // These caught failures missed by the lighter/darker isolated samples.
        func luminance(_ rgb: [Double]) -> Double {
            let linear = rgb.map { $0 <= 0.04045 ? $0 / 12.92 : pow(($0 + 0.055) / 1.055, 2.4) }
            return linear[0] * 0.2126 + linear[1] * 0.7152 + linear[2] * 0.0722
        }
        for scheme in [ColorScheme.light, .dark] {
            let background = (scheme == .light ? [209.0, 210.0, 213.0] : [77.0, 78.0, 78.0]).map { $0 / 255 }
            for contrast in [ColorSchemeContrast.standard, .increased] {
                for style in [MonitorTextStyle.secondary, .tertiary] {
                    let color = style.color(scheme: scheme, contrast: contrast).resolve(in: EnvironmentValues())
                    let foreground = [Double(color.red), Double(color.green), Double(color.blue)]
                    let a = luminance(foreground), b = luminance(background)
                    #expect((max(a, b) + 0.05) / (min(a, b) + 0.05) >= 4.5)
                }
            }
        }
    }

}
