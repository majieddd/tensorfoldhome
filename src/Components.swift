import AppKit
import SwiftUI

// MARK: - cards and text

struct Card<Content: View>: View {
    @Environment(\.pal) var pal
    var padding: CGFloat = 24
    @ViewBuilder var content: () -> Content
    var body: some View {
        VStack(alignment: .leading, spacing: 0) { content() }
            .padding(padding)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: 20).fill(pal.surface))
            .overlay(RoundedRectangle(cornerRadius: 20).stroke(pal.line, lineWidth: 1))
            .shadow(color: .black.opacity(pal.dark ? 0.0 : 0.05), radius: 4, y: 2)
    }
}

struct CardTitle: View {
    @Environment(\.pal) var pal
    let text: String
    var body: some View { Text(text).outfit(16, .bold).foregroundStyle(pal.ink) }
}

struct Muted: View {
    @Environment(\.pal) var pal
    let text: String
    var size: CGFloat = 12
    var body: some View {
        Text(text).outfit(size).foregroundStyle(pal.inkMuted).fixedSize(horizontal: false, vertical: true)
    }
}

// MARK: - buttons

struct HoverState: ViewModifier {
    @Binding var hovering: Bool
    func body(content: Content) -> some View { content.onHover { hovering = $0 } }
}

struct PrimaryButtonStyle: ButtonStyle {
    @Environment(\.pal) var pal
    @Environment(\.isEnabled) var enabled
    var height: CGFloat = 40
    var hPad: CGFloat = 18
    func makeBody(configuration: Configuration) -> some View {
        Inner(configuration: configuration, pal: pal, enabled: enabled, height: height, hPad: hPad)
    }
    struct Inner: View {
        let configuration: ButtonStyle.Configuration
        let pal: Palette
        let enabled: Bool
        let height: CGFloat
        let hPad: CGFloat
        @State var hover = false
        var body: some View {
            configuration.label
                .outfit(14, .bold)
                .foregroundStyle(pal.accentInk)
                .padding(.horizontal, hPad)
                .frame(height: height)
                .background(RoundedRectangle(cornerRadius: 14).fill(hover && enabled ? pal.accentHover : pal.accent))
                .shadow(color: pal.accent.opacity(enabled ? 0.24 : 0), radius: 8, y: 4)
                .opacity(enabled ? (configuration.isPressed ? 0.85 : 1) : 0.45)
                .contentShape(Rectangle())
                .onHover { hover = $0 }
        }
    }
}

struct SecondaryButtonStyle: ButtonStyle {
    @Environment(\.pal) var pal
    @Environment(\.isEnabled) var enabled
    var height: CGFloat = 40
    func makeBody(configuration: Configuration) -> some View {
        Inner(configuration: configuration, pal: pal, enabled: enabled, height: height)
    }
    struct Inner: View {
        let configuration: ButtonStyle.Configuration
        let pal: Palette
        let enabled: Bool
        let height: CGFloat
        @State var hover = false
        var body: some View {
            configuration.label
                .outfit(14, .bold)
                .foregroundStyle(pal.ink)
                .padding(.horizontal, 16)
                .frame(height: height)
                .background(RoundedRectangle(cornerRadius: 14).fill(hover && enabled ? pal.surface2 : Color.clear))
                .overlay(RoundedRectangle(cornerRadius: 14).stroke(pal.line, lineWidth: 1.5))
                .opacity(enabled ? (configuration.isPressed ? 0.75 : 1) : 0.45)
                .contentShape(Rectangle())
                .onHover { hover = $0 }
        }
    }
}

struct DangerButtonStyle: ButtonStyle {
    @Environment(\.pal) var pal
    @Environment(\.isEnabled) var enabled
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .outfit(14, .bold)
            .foregroundStyle(pal.dangerText)
            .padding(.horizontal, 16)
            .frame(height: 40)
            .background(RoundedRectangle(cornerRadius: 14).fill(pal.dangerTint))
            .opacity(enabled ? (configuration.isPressed ? 0.8 : 1) : 0.45)
    }
}

struct IconButton: View {
    @Environment(\.pal) var pal
    let symbol: String
    let help: String
    var size: CGFloat = 36
    var iconSize: CGFloat = 16
    var tint: Color? = nil
    let action: () -> Void
    @State var hover = false
    var body: some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: iconSize, weight: .medium))
                .foregroundStyle(tint ?? pal.inkSoft)
                .frame(width: size, height: size)
                .background(RoundedRectangle(cornerRadius: 10).fill(hover ? pal.surface2 : Color.clear))
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(help)
        .onHover { hover = $0 }
    }
}

// MARK: - switch, radio rows, inputs

struct Switch: View {
    @Environment(\.pal) var pal
    @Environment(\.isEnabled) var enabled
    @Binding var isOn: Bool
    var body: some View {
        ZStack(alignment: isOn ? .trailing : .leading) {
            Capsule().fill(isOn ? pal.accent : pal.line).frame(width: 44, height: 24)
            Circle().fill(.white).frame(width: 18, height: 18).padding(3)
                .shadow(color: .black.opacity(0.2), radius: 1, y: 1)
        }
        .animation(.easeOut(duration: 0.15), value: isOn)
        .opacity(enabled ? 1 : 0.45)
        .contentShape(Rectangle())
        .onTapGesture { if enabled { isOn.toggle() } }
        .accessibilityAddTraits(.isButton)
        .accessibilityValue(isOn ? "on" : "off")
    }
}

/// A setting row: title and explanation on the left, a switch on the right.
struct ToggleRow: View {
    @Environment(\.pal) var pal
    let title: String
    let sub: String
    @Binding var isOn: Bool
    var body: some View {
        HStack(alignment: .center, spacing: 16) {
            VStack(alignment: .leading, spacing: 2) {
                Text(title).outfit(14, .medium).foregroundStyle(pal.inkSoft)
                Muted(text: sub)
            }
            Spacer(minLength: 0)
            Switch(isOn: $isOn)
        }
        .padding(.top, 16)
    }
}

struct RadioRow<Content: View>: View {
    @Environment(\.pal) var pal
    @Environment(\.isEnabled) var enabled
    let selected: Bool
    let action: () -> Void
    @ViewBuilder var content: () -> Content
    @State var hover = false
    var body: some View {
        Button(action: action) {
            HStack(spacing: 14) {
                ZStack {
                    Circle().stroke(selected ? pal.accent : pal.line, lineWidth: 2).frame(width: 20, height: 20)
                    if selected { Circle().fill(pal.accent).frame(width: 10, height: 10) }
                }
                VStack(alignment: .leading, spacing: 2) { content() }
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 14)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: 14).fill(selected ? pal.accentTint : (hover ? pal.surface2 : Color.clear)))
            .overlay(RoundedRectangle(cornerRadius: 14).stroke(selected ? pal.accent : pal.line, lineWidth: 1.5))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .opacity(enabled ? 1 : 0.5)
        .onHover { hover = $0 }
    }
}

/// The web app's segmented control (Sampling's thinking level, the context sizes, the log picker).
struct Segmented<T: Hashable>: View {
    @Environment(\.pal) var pal
    @Environment(\.isEnabled) var enabled
    let options: [(T, String)]
    @Binding var selection: T
    var fill = true
    var body: some View {
        HStack(spacing: 4) {
            ForEach(Array(options.enumerated()), id: \.offset) { _, o in
                let on = o.0 == selection
                Button { selection = o.0 } label: {
                    Text(o.1).outfit(13, .bold)
                        .foregroundStyle(on ? pal.ink : pal.inkMuted)
                        .lineLimit(1)
                        .padding(.horizontal, 12)
                        .frame(maxWidth: fill ? .infinity : nil, minHeight: 32)
                        .background(RoundedRectangle(cornerRadius: 10).fill(on ? pal.surface : Color.clear)
                            .shadow(color: .black.opacity(on && !pal.dark ? 0.08 : 0), radius: 2, y: 1))
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
        }
        .padding(4)
        .background(RoundedRectangle(cornerRadius: 14).fill(pal.surface2))
        .overlay(RoundedRectangle(cornerRadius: 14).stroke(pal.line, lineWidth: 1))
        .opacity(enabled ? 1 : 0.5)
        .fixedSize(horizontal: !fill, vertical: false)
    }
}

/// A card with a bold title, an optional right-hand note and an optional muted explanation.
struct TitledCard<Content: View>: View {
    @Environment(\.pal) var pal
    let title: String
    var trailing: String = ""
    var note: String? = nil
    @ViewBuilder var content: () -> Content
    var body: some View {
        Card {
            HStack(alignment: .firstTextBaseline) {
                CardTitle(text: title)
                Spacer()
                if !trailing.isEmpty { Text(trailing).outfit(12).foregroundStyle(pal.inkMuted) }
            }
            if let note { Muted(text: note, size: 13).padding(.top, 8) }
            content()
        }
    }
}

struct FieldStyle: ViewModifier {
    @Environment(\.pal) var pal
    var mono = false
    func body(content: Content) -> some View {
        content
            .textFieldStyle(.plain)
            .font(mono ? Fonts.mono(13) : Fonts.outfit(14))
            .foregroundStyle(pal.ink)
            .padding(.horizontal, 12)
            .frame(height: 38)
            .background(RoundedRectangle(cornerRadius: 14).fill(pal.surface))
            .overlay(RoundedRectangle(cornerRadius: 14).stroke(pal.line, lineWidth: 1.5))
    }
}

extension View {
    func field(mono: Bool = false) -> some View { modifier(FieldStyle(mono: mono)) }
}

// MARK: - badges, bars, charts

struct Badge: View {
    @Environment(\.pal) var pal
    let text: String
    let tone: Tone
    var body: some View {
        HStack(spacing: 6) {
            Circle().fill(pal.tone(tone)).frame(width: 6, height: 6)
            Text(text).outfit(12, .bold).foregroundStyle(pal.toneText(tone))
        }
        .padding(.horizontal, 10)
        .frame(height: 24)
        .background(Capsule().fill(pal.tint(tone)))
        .overlay(Capsule().stroke(tone == .muted ? pal.line : Color.clear, lineWidth: 1))
    }
}

struct BarView: View {
    @Environment(\.pal) var pal
    var fraction: Double
    var tone: Tone = .accent
    var height: CGFloat = 8
    var indeterminate = false
    @State private var phase: CGFloat = -0.3
    var body: some View {
        GeometryReader { g in
            ZStack(alignment: .leading) {
                Capsule().fill(pal.surface2).overlay(Capsule().stroke(pal.lineSoft, lineWidth: 1))
                if indeterminate {
                    Capsule().fill(pal.tone(tone))
                        .frame(width: g.size.width * 0.3)
                        .offset(x: g.size.width * phase)
                        .onAppear {
                            withAnimation(.easeInOut(duration: 1.1).repeatForever(autoreverses: true)) { phase = 0.7 }
                        }
                } else {
                    Capsule().fill(pal.tone(tone))
                        .frame(width: max(0, min(1, fraction.isFinite ? fraction : 0)) * g.size.width)
                        .animation(.easeOut(duration: 0.3), value: fraction)
                }
            }
            .clipShape(Capsule())
        }
        .frame(height: height)
    }
}

/// A small area chart of the last samples; `second` draws a dashed line on top (prefill next to decode).
struct Sparkline: View {
    @Environment(\.pal) var pal
    var values: [Double]
    var second: [Double] = []
    var maxValue: Double = 0
    var tone: Tone = .accent
    var body: some View {
        GeometryReader { g in
            let top = max(maxValue, (values + second).max() ?? 0, 0.0001)
            let pts = points(values, g.size, top)
            ZStack {
                if pts.count > 1 {
                    Path { p in
                        p.move(to: CGPoint(x: pts[0].x, y: g.size.height))
                        pts.forEach { p.addLine(to: $0) }
                        p.addLine(to: CGPoint(x: pts.last!.x, y: g.size.height))
                        p.closeSubpath()
                    }
                    .fill(pal.tone(tone).opacity(0.14))
                    Path { p in p.addLines(pts) }.stroke(pal.tone(tone), style: StrokeStyle(lineWidth: 2, lineJoin: .round))
                }
                let p2 = points(second, g.size, top)
                if p2.count > 1 {
                    Path { p in p.addLines(p2) }.stroke(pal.info, style: StrokeStyle(lineWidth: 1.5, dash: [4, 3]))
                }
            }
        }
        .frame(height: 40)
    }

    func points(_ v: [Double], _ size: CGSize, _ top: Double) -> [CGPoint] {
        guard v.count > 1 else { return [] }
        let step = size.width / CGFloat(max(1, v.count - 1))
        return v.enumerated().map { i, x in
            CGPoint(x: CGFloat(i) * step, y: size.height - CGFloat(min(1, max(0, x / top))) * (size.height - 2) - 1)
        }
    }
}

/// The context fill gauge: a 270° arc.
struct Gauge270: View {
    @Environment(\.pal) var pal
    var fraction: Double
    var body: some View {
        ZStack {
            Circle().trim(from: 0, to: 0.75)
                .stroke(pal.surface2, style: StrokeStyle(lineWidth: 14, lineCap: .round))
                .rotationEffect(.degrees(135))
            Circle().trim(from: 0, to: 0.75 * max(0.001, min(1, fraction)))
                .stroke(fraction > 0.9 ? pal.danger : fraction > 0.75 ? pal.warn : pal.accent,
                        style: StrokeStyle(lineWidth: 14, lineCap: .round))
                .rotationEffect(.degrees(135))
                .animation(.easeOut(duration: 0.4), value: fraction)
        }
    }
}

/// Two-column label / value rows (the "Model and engine", "This Mac" cards).
struct Facts: View {
    @Environment(\.pal) var pal
    let rows: [(String, String)]
    var labelWidth: CGFloat = 200
    var mono = false
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            ForEach(Array(rows.enumerated()), id: \.offset) { _, row in
                HStack(alignment: .firstTextBaseline, spacing: 0) {
                    Text(row.0).outfit(14).foregroundStyle(pal.inkMuted).frame(width: labelWidth, alignment: .leading)
                    Text(row.1).font(mono ? Fonts.mono(13) : Fonts.outfit(14)).foregroundStyle(pal.inkSoft)
                        .textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
                    Spacer(minLength: 0)
                }
            }
        }
    }
}

/// A monospaced value with a copy button.
struct CopyValue: View {
    @Environment(\.pal) var pal
    @EnvironmentObject var model: AppModel
    let value: String
    var body: some View {
        HStack(spacing: 6) {
            Text(value).font(Fonts.mono(13)).foregroundStyle(pal.inkSoft).textSelection(.enabled)
            IconButton(symbol: "doc.on.doc", help: "Copy", size: 28, iconSize: 13) {
                Clip.copy(value)
                model.toast(.success, "Copied", value)
            }
        }
    }
}

// MARK: - toasts

enum ToastKind { case success, info, warn, error }

struct Toast: Identifiable {
    let id = UUID()
    let kind: ToastKind
    let title: String
    let text: String
    var actionLabel: String? = nil
    var action: (() -> Void)? = nil
}

struct ToastView: View {
    @Environment(\.pal) var pal
    @EnvironmentObject var model: AppModel
    let toast: Toast
    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: icon).font(.system(size: 18, weight: .semibold)).foregroundStyle(color)
            VStack(alignment: .leading, spacing: 2) {
                Text(toast.title).outfit(14, .bold).foregroundStyle(pal.ink)
                if !toast.text.isEmpty {
                    Text(toast.text).outfit(14).foregroundStyle(pal.inkSoft).fixedSize(horizontal: false, vertical: true)
                }
            }
            if let label = toast.actionLabel {
                Button(label) { toast.action?(); model.dismiss(toast) }
                    .buttonStyle(SecondaryButtonStyle(height: 30))
            }
        }
        .padding(.horizontal, 16).padding(.vertical, 14)
        .frame(maxWidth: 420, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 14).fill(pal.surface))
        .overlay(RoundedRectangle(cornerRadius: 14).stroke(pal.line, lineWidth: 1))
        .shadow(color: .black.opacity(0.18), radius: 12, y: 6)
        .onTapGesture { model.dismiss(toast) }
        .transition(.move(edge: .trailing).combined(with: .opacity))
    }
    var icon: String {
        switch toast.kind {
        case .success: return "checkmark.circle.fill"
        case .info: return "info.circle.fill"
        case .warn: return "exclamationmark.triangle.fill"
        case .error: return "xmark.octagon.fill"
        }
    }
    var color: Color {
        switch toast.kind {
        case .success: return pal.accent
        case .info: return pal.info
        case .warn: return pal.warn
        case .error: return pal.danger
        }
    }
}

/// Lets the header drag the window (the title bar is hidden under it).
struct WindowDragArea: NSViewRepresentable {
    final class DragView: NSView {
        override func mouseDown(with event: NSEvent) { window?.performDrag(with: event) }
        override func mouseUp(with event: NSEvent) {
            if event.clickCount == 2 { window?.zoom(nil) }
        }
    }
    func makeNSView(context: Context) -> NSView { DragView() }
    func updateNSView(_ nsView: NSView, context: Context) {}
}
