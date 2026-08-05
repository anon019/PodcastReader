import AppKit
import SwiftUI

enum AppearanceMode: String, CaseIterable, Identifiable {
    case system = "跟随系统"
    case light = "浅色"
    case dark = "深色"

    var id: String { rawValue }

    var colorScheme: ColorScheme? {
        switch self {
        case .system: nil
        case .light: .light
        case .dark: .dark
        }
    }

    var symbol: String {
        switch self {
        case .system: "circle.lefthalf.filled"
        case .light: "sun.max"
        case .dark: "moon.stars"
        }
    }
}

enum FieldNotesTheme {
    static let paper = adaptive(light: 0xFBFAF4, dark: 0x141916)
    static let chrome = adaptive(light: 0xEEF1EB, dark: 0x101512)
    static let selected = adaptive(light: 0xDFE8DD, dark: 0x26362C)
    static let surface = adaptive(light: 0xFFFFFF, dark: 0x1A211C)
    static let surfaceRaised = adaptive(light: 0xF7F7F2, dark: 0x202923)
    static let ink = adaptive(light: 0x28302A, dark: 0xEAF0EA)
    static let bodyText = adaptive(light: 0x1E231F, dark: 0xF1F5F0)
    static let muted = adaptive(light: 0x5F695F, dark: 0xA9B4AB)
    static let action = adaptive(light: 0x58745D, dark: 0x8EB69A)
    static let amber = adaptive(light: 0x875A1E, dark: 0xE1AD63)
    static let unread = action
    static let divider = adaptive(light: 0xD5D9CF, dark: 0x344039)

    private static func adaptive(light: Int, dark: Int) -> Color {
        Color(nsColor: NSColor(name: nil) { appearance in
            let value = appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua ? dark : light
            return NSColor(
                red: CGFloat((value >> 16) & 0xFF) / 255,
                green: CGFloat((value >> 8) & 0xFF) / 255,
                blue: CGFloat(value & 0xFF) / 255,
                alpha: 1
            )
        })
    }
}

extension Font {
    static func fieldTitle(_ size: CGFloat) -> Font {
        .system(size: size, weight: .semibold, design: .serif)
    }

    static func readerBody(_ size: CGFloat) -> Font {
        .custom("PingFangSC-Regular", size: size)
    }

    static func readerBodySemibold(_ size: CGFloat) -> Font {
        .custom("PingFangSC-Semibold", size: size)
    }

    static func readerDisplay(_ size: CGFloat) -> Font {
        .custom("STSongti-SC-Regular", size: size)
    }
}
