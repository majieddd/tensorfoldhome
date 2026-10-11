import SwiftUI

/// The About tab: the model and engine, this Mac, the addresses for other tools (with Hermes's config), settings,
/// and the model settings TensorFold starts with (context length, thinking by default).
struct AboutView: View {
    @EnvironmentObject var model: AppModel
    @Environment(\.pal) var pal

    var body: some View {
        ScrollView {
            VStack(spacing: 20) {
                EngineCard()
                MacCard()
                ConnectCard()
                SettingsCard()
                ModelSettingsCard()
            }
            .frame(maxWidth: 860)
            .padding(24)
            .frame(maxWidth: .infinity)
        }
    }
}

private struct EngineCard: View {
    @EnvironmentObject var model: AppModel

    var body: some View {
        let st = model.status, facts = st["engine_facts"], info = st["model_info"]
        let m = model.currentModel
        var rows: [(String, String)] = []
        rows.append(("Model", model.modelLabel))
        if let repo = m?.repo ?? st["model"]["repo"].string { rows.append(("Hugging Face", repo)) }
        if !info.isNull, info["cached"].bool {
            var f = info["quantization"].str
            if let t = info["model_type"].string, !t.isEmpty { f += " · \(t)" }
            if let l = info["layers"].int { f += ", \(l) layers" }
            rows.append(("Format", f))
            if let s = info["size_gb"].double { rows.append(("On disk", "\(Fmt.n(s, 1)) GB")) }
        } else if m != nil {
            rows.append(("On disk", m?.cachedBytes.map { "\(Fmt.n($0 / 1e9, 1)) GB" } ?? "not downloaded yet: the first start fetches it"))
        }
        let version = st["engine_version"].str
        let line = m?.engine == "native" ? "TensorFold \(version.isEmpty ? "1.0" : version) (native, Homebrew)"
            : "TensorFold \(version.isEmpty ? "0.6" : version) (Python/MLX line\(m?.engine == "tf06" ? ", with the M5 workaround" : ""))"
        rows.append(("Engine", model.engineLoaded ? line : "\(line) · not loaded"))
        if let d = facts["decoder"].string { rows.append(("Decoder", d)) }
        rows.append(("Context", "\(Fmt.n(Double(model.context))) tokens"))
        if !facts.isNull {
            let drafter = facts["drafter"].str
            rows.append(("Drafts", !facts["drafts"].bool ? "off"
                         : drafter.isEmpty || drafter.hasPrefix("none") ? "on: drafts are copied from the prompt (no draft model)"
                         : "on: draft model \(drafter)"))
            if let s = facts["sampling"].string { rows.append(("Sampling default", s)) }
        }
        rows.append(("Thinking default", model.thinkingDefault ? "on" : "off (a request can turn it on)"))
        if let w = facts["weights_gib"].double { rows.append(("Weights in memory", "\(Fmt.n(w, 1)) GiB")) }
        if let b = facts["memory_budget_gib"].double { rows.append(("Memory budget", "\(Fmt.n(b, 1)) GiB")) }
        if let c = facts["concurrency"].int { rows.append(("Concurrency", "up to \(c) requests share each round")) }
        if let l = facts["load_seconds"].double { rows.append(("Load time", "\(Fmt.n(l, 1)) s")) }
        return TitledCard(title: "Model and engine") { Facts(rows: rows, labelWidth: 200).padding(.top, 14) }
    }
}

private struct MacCard: View {
    let f = MacFacts.current
    var body: some View {
        TitledCard(title: "This Mac") {
            Facts(rows: [
                ("Chip", f.chip),
                ("GPU", f.gpuCores.map { "\($0)-core GPU, unified memory" } ?? "Apple GPU"),
                ("CPU", f.coresText),
                ("Memory", "\(Fmt.gb(f.memory, 0)) GB"),
                ("GPU memory limit", f.gpuBudget.map { "\(Fmt.gb($0)) GB (what Metal lets one app use)" } ?? "–"),
                ("System", f.os),
            ], labelWidth: 200).padding(.top, 14)
        }
    }
}

private struct ConnectCard: View {
    @EnvironmentObject var model: AppModel
    @Environment(\.pal) var pal

    var hermes: String {
        """
        model:
          provider: custom
          base_url: \(model.apiURL)
          default: \(model.servedName)
          context_length: \(model.context)
        """
    }

    var body: some View {
        TitledCard(title: "Connect your tools",
                   note: "Any OpenAI- or Anthropic-compatible client works with these addresses: Hermes, Open WebUI, editors, scripts. Whatever model name a client sends is answered by the loaded model.") {
            VStack(alignment: .leading, spacing: 10) {
                row("OpenAI base URL", model.apiURL)
                row("Anthropic base URL", model.base)
                row("Model id", model.servedName)
                if model.share {
                    ForEach(Net.lanAddresses(), id: \.self) { ip in row("From the network", "http://\(ip):\(model.gatewayPort)/v1") }
                }
                HStack(alignment: .firstTextBaseline, spacing: 0) {
                    Text("API key").outfit(14).foregroundStyle(pal.inkMuted).frame(width: 200, alignment: .leading)
                    Text(model.share && model.requireKey ? "required from other computers (Server > Network)" : "none needed on this Mac (send any value if a client insists)")
                        .outfit(14).foregroundStyle(pal.inkSoft)
                }
                row("Context window", "\(Fmt.n(Double(model.context))) tokens", copy: false)
            }
            .padding(.top, 14)
            HStack {
                Text("Hermes (~/.hermes/config.yaml)").outfit(13, .medium).foregroundStyle(pal.inkSoft)
                Spacer()
            }
            .padding(.top, 18).padding(.bottom, 8)
            MarkdownView(text: "```yaml\n\(hermes)\n```")
        }
    }

    func row(_ label: String, _ value: String, copy: Bool = true) -> some View {
        HStack(alignment: .center, spacing: 0) {
            Text(label).outfit(14).foregroundStyle(pal.inkMuted).frame(width: 200, alignment: .leading)
            if copy { CopyValue(value: value) } else { Text(value).outfit(14).foregroundStyle(pal.inkSoft) }
            Spacer(minLength: 0)
        }
    }
}

private struct SettingsCard: View {
    @EnvironmentObject var model: AppModel
    @Environment(\.pal) var pal

    var body: some View {
        TitledCard(title: "Settings") {
            HStack {
                Text("Theme").outfit(13, .medium).foregroundStyle(pal.inkSoft)
                Spacer()
                Segmented(options: [("system", "Match macOS"), ("light", "Light"), ("dark", "Dark")],
                          selection: Binding(get: { model.settings.theme }, set: { model.setTheme($0) }), fill: false)
            }
            .padding(.top, 16)
            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 0) {
                    Text("Chats and settings are kept on this Mac only. ").outfit(12).foregroundStyle(pal.inkMuted)
                    Link("TensorFold on GitHub", destination: URL(string: "https://github.com/ashhart/TensorFold")!)
                        .font(Fonts.outfit(12, .medium)).foregroundStyle(pal.accentText)
                    Text(" · ").outfit(12).foregroundStyle(pal.inkMuted)
                    Link("TensorFold Home", destination: URL(string: "https://github.com/\(SelfUpdater.repo)")!)
                        .font(Fonts.outfit(12, .medium)).foregroundStyle(pal.accentText)
                }
                Muted(text: "TensorFold Home \(AppModel.version) · unofficial · MIT. Not affiliated with TensorFold or its author. The window follows the look of StrataHome.")
            }
            .padding(.top, 16)
        }
    }
}

private struct ModelSettingsCard: View {
    @EnvironmentObject var model: AppModel
    @Environment(\.pal) var pal
    @State private var pick = 0
    static let sizes = [16384, 32768, 65536, 131072, 262144]

    var body: some View {
        let now = model.context
        let sizes = (Self.sizes.contains(now) ? Self.sizes : (Self.sizes + [now]).sorted())
        TitledCard(title: "Model settings", trailing: "now \(Fmt.k(Double(now))) tokens",
                   note: "What TensorFold starts the model with. They are kept in config.env, so tfctl, the menu bar and Hermes see the same values.") {
            Text("Context length").outfit(13, .medium).foregroundStyle(pal.inkSoft).padding(.top, 16)
            Muted(text: "How much one conversation can hold, prompt plus reply. A longer context keeps more of a long chat or a big file in view and reserves more memory.")
                .padding(.top, 4).padding(.bottom, 10)
            Segmented(options: sizes.map { ($0, Fmt.k(Double($0))) }, selection: $pick, fill: false)
            Muted(text: hint(pick, now)).padding(.top, 10)
            HStack(spacing: 10) {
                Button("Save and restart") { model.setContext(pick, restart: true) }.buttonStyle(PrimaryButtonStyle())
                Button("Save for next start") { model.setContext(pick, restart: false) }.buttonStyle(SecondaryButtonStyle())
            }
            .disabled(pick == now || pick == 0)
            .padding(.top, 14)
            Rectangle().fill(pal.lineSoft).frame(height: 1).padding(.vertical, 18)
            ToggleRow(title: "Think by default",
                      sub: "Whether a request that doesn't say opens a reasoning block. Off answers sooner. Chat's Sampling drawer sets it per message. Changing it restarts the model.",
                      isOn: Binding(get: { model.thinkingDefault }, set: { model.setThinkingDefault($0) }))
                .padding(.top, -16)
        }
        .onAppear { pick = now }
        .onChange(of: now) { _, v in pick = v }
    }

    func hint(_ n: Int, _ now: Int) -> String {
        guard n > 0 else { return "" }
        var t = "\(Fmt.n(Double(n))) tokens"
        if n < 64000 { t += ". Hermes refuses endpoints under 64,000 tokens" }
        if n > 131072 { t += ". Long contexts need more memory; if the model fails to load, pick a smaller size" }
        if n != now { t += ". Changes from \(Fmt.k(Double(now)))" }
        return t + "."
    }
}
