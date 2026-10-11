import SwiftUI

/// StrataHome's Sampling drawer: thinking level, temperature, top-p, top-k, max tokens, seed, and two switches.
/// "Use for other apps too" stores the values in the gateway, which fills them into any request that leaves them out.
struct SamplingDrawer: View {
    @EnvironmentObject var model: AppModel
    @Environment(\.pal) var pal

    var body: some View {
        ZStack(alignment: .trailing) {
            if model.drawerOpen {
                pal.scrim.contentShape(Rectangle())
                    .onTapGesture { model.drawerOpen = false }
                    .transition(.opacity)
                SamplingPanel()
                    .frame(width: 360)
                    .frame(maxHeight: .infinity)
                    .background(pal.surface)
                    .overlay(Rectangle().fill(pal.line).frame(width: 1), alignment: .leading)
                    .shadow(color: .black.opacity(0.3), radius: 20, x: -6)
                    .transition(.move(edge: .trailing))
            }
        }
        .animation(.easeOut(duration: 0.22), value: model.drawerOpen)
    }
}

private struct SamplingPanel: View {
    @EnvironmentObject var model: AppModel
    @Environment(\.pal) var pal
    @State private var effort = "none"
    @State private var temp = 0.0
    @State private var topP = 0.95
    @State private var topK = 20.0
    @State private var maxTokens = ""
    @State private var seed = ""
    @State private var showThinking = true
    @State private var share = false
    @State private var sharedOn = false

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("Sampling").outfit(16, .bold).foregroundStyle(pal.ink)
                Spacer()
                IconButton(symbol: "chevron.right", help: "Close") { model.drawerOpen = false }
            }
            .padding(.leading, 20).padding(.trailing, 12).padding(.vertical, 12)
            Rectangle().fill(pal.line).frame(height: 1)
            ScrollView {
                VStack(alignment: .leading, spacing: 22) {
                    field("Thinking", effortNote) {
                        Segmented(options: [("none", "Off"), ("low", "Low"), ("medium", "Medium"), ("high", "High")], selection: $effort)
                    }
                    field("Temperature", temp == 0 ? "0 · greedy" : String(format: "%.2f", temp),
                          hint: "0 = always the most likely token (exact, repeatable, and what TensorFold's drafts are checked against).") {
                        Slider(value: snapped($temp, 0.05), in: 0...1.5).tint(pal.accent)
                    }
                    field("Top-p", String(format: "%.2f", topP)) {
                        Slider(value: snapped($topP, 0.05), in: 0.05...1).tint(pal.accent).disabled(temp == 0)
                    }
                    field("Top-k", "\(Int(topK))") {
                        Slider(value: snapped($topK, 1), in: 1...64).tint(pal.accent).disabled(temp == 0)
                    }
                    field("Max tokens", "empty = the engine's default (4,096)") {
                        TextField("", text: $maxTokens).field()
                    }
                    field("Seed", "empty = random") {
                        TextField("", text: $seed).field()
                    }
                    toggle("Show thinking", "expanded while it streams", $showThinking)
                    toggle("Use for other apps too",
                           "Hermes, Open WebUI and other clients get these settings for anything they don't set themselves", $share)
                    HStack(spacing: 12) {
                        Button { load(Settings()) } label: { Text("Reset").frame(maxWidth: .infinity) }.buttonStyle(SecondaryButtonStyle())
                        Button { apply() } label: { Text("Apply").frame(maxWidth: .infinity) }.buttonStyle(PrimaryButtonStyle())
                    }
                }
                .padding(20)
            }
        }
        .onAppear {
            load(model.settings)
            Task {
                let j = await HTTP.json("\(model.base)/tf/settings")
                sharedOn = j?["shared"].bool ?? false
                share = sharedOn
            }
        }
    }

    /// Sliders without tick marks (a stepped Slider draws one per step), rounded to the step instead.
    func snapped(_ b: Binding<Double>, _ step: Double) -> Binding<Double> {
        Binding(get: { b.wrappedValue }, set: { b.wrappedValue = ($0 / step).rounded() * step })
    }

    var effortNote: String {
        switch effort {
        case "none": return "answers right away (fastest)"
        case "low": return "short"
        case "medium": return "medium"
        default: return "thorough"
        }
    }

    func field<C: View>(_ label: String, _ output: String, hint: String? = nil, @ViewBuilder _ control: () -> C) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text(label).outfit(13, .medium).foregroundStyle(pal.inkSoft)
                Spacer()
                Text(output).outfit(13).foregroundStyle(pal.inkMuted)
            }
            control()
            if let hint { Muted(text: hint) }
        }
    }

    func toggle(_ title: String, _ sub: String, _ on: Binding<Bool>) -> some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                Text(title).outfit(13, .medium).foregroundStyle(pal.inkSoft)
                Muted(text: sub)
            }
            Spacer(minLength: 0)
            Switch(isOn: on)
        }
    }

    func load(_ s: Settings) {
        effort = s.effort; temp = s.temperature; topP = s.topP; topK = Double(s.topK)
        maxTokens = s.maxTokens; seed = s.seed; showThinking = s.showThinking
        share = sharedOn
    }

    func apply() {
        var s = model.settings
        s.effort = effort
        s.temperature = (temp * 100).rounded() / 100
        s.topP = (topP * 100).rounded() / 100
        s.topK = Int(topK)
        s.maxTokens = maxTokens.trimmingCharacters(in: .whitespaces)
        s.seed = seed.trimmingCharacters(in: .whitespaces)
        s.showThinking = showThinking
        model.settings = s
        model.drawerOpen = false
        let wantShare = share
        guard wantShare || sharedOn else {
            model.toast(.success, "Sampling saved", "Used by the next message in this chat.", seconds: 2.5)
            return
        }
        var defaults: Any = NSNull()
        if wantShare {
            var d: [String: Any] = ["reasoning_effort": s.effort, "temperature": s.temperature]
            if s.temperature > 0 { d["top_p"] = s.topP; d["top_k"] = s.topK }
            if let n = Int(s.seed) { d["seed"] = n }
            if let n = Int(s.maxTokens), n > 0 { d["max_tokens"] = n }
            defaults = d
        }
        Task {
            let (code, j) = await HTTP.post("\(model.base)/tf/settings", ["defaults": defaults])
            if code != 200 {
                model.toast(.error, "Saved here, but not for other apps", model.gatewayUp ? "The endpoint answered \(code)." : "The endpoint is not running.", seconds: 6)
                return
            }
            sharedOn = j["shared"].bool
            model.toast(.success, "Sampling saved",
                        sharedOn ? "Other apps use these settings from their next request." : "Other apps use their own settings again.", seconds: 4)
        }
    }
}
