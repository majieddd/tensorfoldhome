import SwiftUI

/// The window: StrataHome's header (brand, tabs, status pill, theme button), one page per tab, the Sampling
/// drawer over everything, and the toasts in the corner.
struct MainView: View {
    @EnvironmentObject var model: AppModel

    var body: some View {
        let pal = model.pal
        ZStack(alignment: .bottomTrailing) {
            VStack(spacing: 0) {
                Header()
                ZStack {
                    // Chat stays alive (its scroll position and composer) while other tabs show
                    ChatView().opacity(model.tab == .chat ? 1 : 0).allowsHitTesting(model.tab == .chat)
                    switch model.tab {
                    case .monitor: MonitorView()
                    case .about: AboutView()
                    case .server: ServerView()
                    case .chat: EmptyView()
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
            SamplingDrawer()
            VStack(alignment: .trailing, spacing: 10) {
                ForEach(model.toasts) { ToastView(toast: $0) }
            }
            .padding(20)
        }
        .background(pal.bg)
        .ignoresSafeArea()   // the header takes the hidden title bar's place
        .environment(\.pal, pal)
        .preferredColorScheme(model.dark ? .dark : .light)
    }
}

private struct Header: View {
    @EnvironmentObject var model: AppModel
    @Environment(\.pal) var pal

    var body: some View {
        HStack(spacing: 16) {
            HStack(spacing: 3) {
                Text("TensorFold").outfit(18, .black).foregroundStyle(pal.ink)
                Text("Home").outfit(18, .medium).foregroundStyle(pal.inkMuted)
            }
            HStack(spacing: 4) {
                ForEach(Tab.allCases) { t in TabButton(tab: t) }
            }
            .padding(4)
            .background(RoundedRectangle(cornerRadius: 14).fill(pal.surface2))
            .overlay(RoundedRectangle(cornerRadius: 14).stroke(pal.line, lineWidth: 1))
            Spacer(minLength: 8)
            StatusPill()
            IconButton(symbol: model.dark ? "sun.max" : "moon", help: "Light / dark", iconSize: 18) {
                model.setTheme(model.dark ? "light" : "dark")
            }
        }
        .padding(.leading, 84)   // the window's close / minimise / zoom buttons sit here
        .padding(.trailing, 20)
        .frame(height: 60)
        .background(WindowDragArea())
        .background(pal.surface)
        .overlay(Rectangle().fill(pal.line).frame(height: 1), alignment: .bottom)
    }
}

private struct TabButton: View {
    @EnvironmentObject var model: AppModel
    @Environment(\.pal) var pal
    let tab: Tab
    @State private var hover = false

    var body: some View {
        let on = model.tab == tab
        Button { model.tab = tab } label: {
            HStack(spacing: 8) {
                Image(systemName: tab.symbol).font(.system(size: 13, weight: .medium))
                Text(tab.title).outfit(14, on ? .bold : .medium)
            }
            .foregroundStyle(on ? pal.ink : (hover ? pal.inkSoft : pal.inkMuted))
            .padding(.horizontal, 14)
            .frame(height: 36)
            .background(RoundedRectangle(cornerRadius: 10).fill(on ? pal.surface : Color.clear)
                .shadow(color: .black.opacity(on && !pal.dark ? 0.08 : 0), radius: 2, y: 1))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hover = $0 }
    }
}

private struct StatusPill: View {
    @EnvironmentObject var model: AppModel
    @Environment(\.pal) var pal
    @State private var pulse = false

    var body: some View {
        let p = model.pill
        HStack(spacing: 6) {
            ZStack {
                if p.halo {
                    Circle().fill(pal.tint(p.tone)).frame(width: 16, height: 16)
                        .scaleEffect(pulse ? 1.15 : 0.8)
                        .animation(.easeInOut(duration: 0.9).repeatForever(autoreverses: true), value: pulse)
                        .onAppear { pulse = true }
                }
                Circle().fill(pal.tone(p.tone)).frame(width: 8, height: 8)
            }
            .frame(width: 16, height: 16)
            Text(p.text).outfit(13, .medium).foregroundStyle(pal.inkSoft).lineLimit(1)
        }
        .padding(.horizontal, 12)
        .frame(height: 30)
        .background(Capsule().fill(pal.surface2))
        .overlay(Capsule().stroke(pal.line, lineWidth: 1))
        .onTapGesture { model.tab = .monitor }
        .help("What the model is doing. Click for the Monitor.")
    }
}

extension AppModel {
    func setTheme(_ theme: String) {
        settings.theme = theme
        applyAppearance()
    }

    func applyAppearance() {
        switch settings.theme {
        case "dark": NSApp.appearance = NSAppearance(named: .darkAqua)
        case "light": NSApp.appearance = NSAppearance(named: .aqua)
        default: NSApp.appearance = nil
        }
        systemDark = NSApp.effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
        objectWillChange.send()
    }
}
