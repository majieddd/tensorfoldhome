import AppKit
import CoreText
import SwiftUI

extension Color {
    /// #RRGGBB or #AARRGGBB (the WPF order StrataHome's tokens use).
    init(hex: String) {
        var s = hex.trimmingCharacters(in: .whitespaces)
        if s.hasPrefix("#") { s.removeFirst() }
        var v: UInt64 = 0
        Scanner(string: s).scanHexInt64(&v)
        let a, r, g, b: Double
        if s.count == 8 {
            a = Double((v >> 24) & 0xFF) / 255; r = Double((v >> 16) & 0xFF) / 255
            g = Double((v >> 8) & 0xFF) / 255; b = Double(v & 0xFF) / 255
        } else {
            a = 1; r = Double((v >> 16) & 0xFF) / 255; g = Double((v >> 8) & 0xFF) / 255; b = Double(v & 0xFF) / 255
        }
        self.init(.sRGB, red: r, green: g, blue: b, opacity: a)
    }
}

/// The colour tokens StrataHome took from Strata's web app (tokens.css), light and dark.
struct Palette {
    let dark: Bool
    let bg, surface, surface2, line, lineSoft, ink, inkSoft, inkMuted: Color
    let accent, accentHover, accentInk, accentTint, accentText, focus: Color
    let info, infoTint, infoText, warn, warnTint, warnText, danger, dangerTint, dangerText: Color
    let codeBg, codeInk, scrim: Color

    static let light = Palette(
        dark: false,
        bg: Color(hex: "#F9FAFB"), surface: Color(hex: "#FFFFFF"), surface2: Color(hex: "#F7F7F7"),
        line: Color(hex: "#DEE5EE"), lineSoft: Color(hex: "#EEEEEE"),
        ink: Color(hex: "#221E1F"), inkSoft: Color(hex: "#303030"), inkMuted: Color(hex: "#6F6F6F"),
        accent: Color(hex: "#10B981"), accentHover: Color(hex: "#0C8A60"), accentInk: Color(hex: "#FFFFFF"),
        accentTint: Color(hex: "#ECFDF5"), accentText: Color(hex: "#0C8A60"), focus: Color(hex: "#405DE6"),
        info: Color(hex: "#0F97FF"), infoTint: Color(hex: "#E8F4FF"), infoText: Color(hex: "#0668C2"),
        warn: Color(hex: "#E39B0B"), warnTint: Color(hex: "#FFF6E0"), warnText: Color(hex: "#8A5A00"),
        danger: Color(hex: "#E0283F"), dangerTint: Color(hex: "#FDECEE"), dangerText: Color(hex: "#B01A2E"),
        codeBg: Color(hex: "#1B1F23"), codeInk: Color(hex: "#E6E9EC"), scrim: Color(hex: "#2E0F172A"))

    static let night = Palette(
        dark: true,
        bg: Color(hex: "#0E1113"), surface: Color(hex: "#161A1D"), surface2: Color(hex: "#1D2226"),
        line: Color(hex: "#2A3036"), lineSoft: Color(hex: "#22272C"),
        ink: Color(hex: "#EEF1F3"), inkSoft: Color(hex: "#C7CDD3"), inkMuted: Color(hex: "#8E979F"),
        accent: Color(hex: "#34D399"), accentHover: Color(hex: "#4ADE80"), accentInk: Color(hex: "#052E20"),
        accentTint: Color(hex: "#1F34D399"), accentText: Color(hex: "#4ADE80"), focus: Color(hex: "#7B93FF"),
        info: Color(hex: "#3AA9FF"), infoTint: Color(hex: "#1F3AA9FF"), infoText: Color(hex: "#7CC4FF"),
        warn: Color(hex: "#F5B53D"), warnTint: Color(hex: "#1FF5B53D"), warnText: Color(hex: "#F8C96A"),
        danger: Color(hex: "#FF5A6E"), dangerTint: Color(hex: "#1FFF5A6E"), dangerText: Color(hex: "#FF8A98"),
        codeBg: Color(hex: "#0A0C0E"), codeInk: Color(hex: "#E6E9EC"), scrim: Color(hex: "#59000000"))

    func tone(_ t: Tone) -> Color {
        switch t {
        case .accent: return accent
        case .info: return info
        case .warn: return warn
        case .danger: return danger
        case .muted: return inkMuted
        }
    }
    func tint(_ t: Tone) -> Color {
        switch t {
        case .accent: return accentTint
        case .info: return infoTint
        case .warn: return warnTint
        case .danger: return dangerTint
        case .muted: return surface2
        }
    }
    func toneText(_ t: Tone) -> Color {
        switch t {
        case .accent: return accentText
        case .info: return infoText
        case .warn: return warnText
        case .danger: return dangerText
        case .muted: return inkSoft
        }
    }
}

enum Tone { case accent, info, warn, danger, muted }

private struct PaletteKey: EnvironmentKey { static let defaultValue = Palette.light }
extension EnvironmentValues {
    var pal: Palette {
        get { self[PaletteKey.self] }
        set { self[PaletteKey.self] = newValue }
    }
}

/// The Outfit font (SIL OFL 1.1), bundled in Resources/fonts and registered for this process at launch.
enum Fonts {
    static var registered = false

    static func register() {
        guard !registered else { return }
        let dir = Bundle.main.resourceURL?.appendingPathComponent("fonts")
        let fallback = URL(fileURLWithPath: CommandLine.arguments[0]).deletingLastPathComponent()
            .appendingPathComponent("../../assets/fonts").standardized
        for base in [dir, fallback].compactMap({ $0 }) {
            guard let files = try? FileManager.default.contentsOfDirectory(at: base, includingPropertiesForKeys: nil) else { continue }
            for f in files where f.pathExtension == "ttf" {
                CTFontManagerRegisterFontsForURL(f as CFURL, .process, nil)
            }
            if NSFont(name: "Outfit-Regular", size: 12) != nil { registered = true; return }
        }
    }

    enum Weight { case regular, medium, bold, black }

    static func outfit(_ size: CGFloat, _ w: Weight = .regular) -> Font {
        let name: String
        switch w {
        case .regular: name = "Outfit-Regular"
        case .medium: name = "Outfit-Medium"
        case .bold: name = "Outfit-Bold"
        case .black: name = "Outfit-Black"
        }
        if registered { return .custom(name, size: size) }
        let fw: Font.Weight = w == .regular ? .regular : w == .medium ? .medium : w == .bold ? .bold : .black
        return .system(size: size, weight: fw)
    }

    static func mono(_ size: CGFloat) -> Font { .system(size: size, design: .monospaced) }
}

extension View {
    func outfit(_ size: CGFloat, _ w: Fonts.Weight = .regular) -> some View { font(Fonts.outfit(size, w)) }
}
