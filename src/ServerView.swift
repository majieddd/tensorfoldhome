import AppKit
import SwiftUI

/// The Server tab: start and stop, the model, the memory mode, the network, the options, updates and the logs.
struct ServerView: View {
    @EnvironmentObject var model: AppModel
    @EnvironmentObject var setup: BackendSetup

    var body: some View {
        ScrollView {
            VStack(spacing: 20) {
                StatusCard()
                if !setup.ready || setup.running { SetupCard() }
                ModelCard()
                NetworkCard()
                OptionsCard()
                UpdatesCard(engine: model.engineUpdates, app: model.updater)
                LogCard()
            }
            .frame(maxWidth: 860)
            .padding(24)
            .frame(maxWidth: .infinity)
        }
    }
}

// MARK: - status

private struct StatusCard: View {
    @EnvironmentObject var model: AppModel
    @Environment(\.pal) var pal

    var body: some View {
        let s = model.runState
        let busy = model.isWorking("server")
        Card {
            HStack(alignment: .center, spacing: 14) {
                Circle().fill(pal.tone(s.tone)).frame(width: 14, height: 14)
                VStack(alignment: .leading, spacing: 2) {
                    Text(s.title).outfit(24, .black).foregroundStyle(pal.ink)
                    Text(detail(s)).outfit(14).foregroundStyle(pal.inkMuted).fixedSize(horizontal: false, vertical: true)
                }
            }
            HStack(spacing: 10) {
                Button("Start") { model.start() }.buttonStyle(PrimaryButtonStyle())
                    .disabled(busy || s != .stopped)
                Button("Stop") { model.stop() }.buttonStyle(SecondaryButtonStyle())
                    .disabled(busy || s == .stopped || s == .stopping)
                Button("Restart") { model.restart() }.buttonStyle(SecondaryButtonStyle())
                    .disabled(busy || s == .stopped || s == .stopping || s == .starting)
                Button(model.engineLoaded || s == .loading ? "Free memory" : "Load now") { model.toggleMemory() }
                    .buttonStyle(SecondaryButtonStyle())
                    .disabled(busy || s == .stopped || s == .starting || s == .stopping)
                    .help("Unload the model and give its memory back to macOS; the endpoint stays and loads it again on the next request.")
                Button("Copy API URL") { model.copyURL() }.buttonStyle(SecondaryButtonStyle())
            }
            .padding(.top, 18)
            Grid(alignment: .leading, horizontalSpacing: 0, verticalSpacing: 6) {
                GridRow {
                    Text("Endpoint").outfit(14).foregroundStyle(pal.inkMuted).frame(width: 160, alignment: .leading)
                    Text(model.apiURL).font(Fonts.mono(13)).foregroundStyle(pal.inkSoft).textSelection(.enabled)
                }
                GridRow {
                    Text("Uptime").outfit(14).foregroundStyle(pal.inkMuted)
                    Text(uptime).outfit(14).foregroundStyle(pal.inkSoft)
                }
                if let r = model.status["idle_remaining_s"].double, model.engineLoaded {
                    GridRow {
                        Text("Unloads").outfit(14).foregroundStyle(pal.inkMuted)
                        Text("in \(Fmt.n(max(1, r / 60))) min without a request").outfit(14).foregroundStyle(pal.inkSoft)
                    }
                }
            }
            .padding(.top, 14)
        }
    }

    var uptime: String {
        guard model.engineLoaded, let since = model.status["engine_up_since"].double else { return "–" }
        var t = Fmt.duration(Date().timeIntervalSince1970 - since)
        if let l = model.status["engine_facts"]["load_seconds"].double { t += "   (model loaded in \(Fmt.n(l)) s)" }
        return t
    }

    func detail(_ s: RunState) -> String {
        let label = model.modelLabel
        switch s {
        case .ready: return "Serving \(label) at \(model.apiURL)"
        case .unloaded: return "The endpoint is up at \(model.apiURL). \(label) loads with the next request."
        case .loading:
            return "Loading \(label)…" + (model.currentModel?.cachedBytes == nil ? " The first start downloads it from Hugging Face." : "")
        case .starting: return "Starting the endpoint…"
        case .stopping: return "Stopping…"
        case .error:
            let code = model.status["engine_last_exit"].int.map { " with code \($0)" } ?? ""
            return "The engine exited\(code). The Engine log below says why."
        case .stopped:
            return model.backendInstalled ? "Start runs the endpoint and loads \(label). Hermes and other apps reach it at \(model.apiURL)."
                                          : "TensorFold is not set up on this Mac yet. Use Set up below."
        }
    }
}

// MARK: - first-run setup

private struct SetupCard: View {
    @EnvironmentObject var setup: BackendSetup
    @EnvironmentObject var model: AppModel
    @Environment(\.pal) var pal
    @State private var webui = false

    var body: some View {
        TitledCard(title: "Set up TensorFold",
                   note: "Installs what TensorFold Home drives: TensorFold 1.0 from Homebrew, TensorFold 0.6 in its own Python environment (it runs the 9B models), the endpoint and the daily updater. Models download from Hugging Face the first time they start.") {
            VStack(alignment: .leading, spacing: 8) {
                ForEach(setup.checks, id: \.name) { c in
                    HStack(spacing: 10) {
                        Image(systemName: c.ok ? "checkmark.circle.fill" : c.optional ? "circle.dashed" : "xmark.circle")
                            .foregroundStyle(c.ok ? pal.accent : c.optional ? pal.inkMuted : pal.danger)
                        Text(c.name).outfit(14, .medium).foregroundStyle(pal.inkSoft)
                        Text(c.detail).outfit(12).foregroundStyle(pal.inkMuted).lineLimit(1)
                    }
                }
            }
            .padding(.top, 14)
            if !setup.homebrew {
                Muted(text: "Homebrew is needed first. Install it from brew.sh, then come back here.").padding(.top, 10)
            }
            HStack(spacing: 12) {
                Button(setup.running ? "Setting up…" : "Set up") { setup.install(webui: webui, model: model) }
                    .buttonStyle(PrimaryButtonStyle())
                    .disabled(setup.running || !setup.homebrew)
                Toggle("Also install Open WebUI (a browser chat, about 2 GB)", isOn: $webui)
                    .toggleStyle(.checkbox).font(Fonts.outfit(13)).foregroundStyle(pal.inkSoft)
            }
            .padding(.top, 16)
            if !setup.output.isEmpty {
                ScrollView {
                    Text(setup.output).font(Fonts.mono(11)).foregroundStyle(pal.codeInk)
                        .frame(maxWidth: .infinity, alignment: .leading).textSelection(.enabled).padding(12)
                }
                .frame(height: 180)
                .background(RoundedRectangle(cornerRadius: 12).fill(pal.codeBg))
                .padding(.top, 12)
            }
        }
    }
}

// MARK: - model + memory

private struct ModelCard: View {
    @EnvironmentObject var model: AppModel
    @Environment(\.pal) var pal
    @State private var sizes: [String: Double] = [:]
    @State private var adding = false
    @State private var repo = ""
    @State private var engine = "tf06"
    @State private var idleText = ""

    var body: some View {
        Card {
            CardTitle(text: "Model")
            VStack(spacing: 8) {
                if model.models.isEmpty {
                    Text("No models listed. Add one below, or set up TensorFold first.").outfit(14).foregroundStyle(pal.dangerText)
                }
                ForEach(model.models) { m in
                    RadioRow(selected: m.key == model.currentModelKey, action: { model.useModel(m) }) {
                        HStack(spacing: 8) {
                            Text(m.label).outfit(14, .bold).foregroundStyle(pal.ink)
                            if model.isWorking("model") && m.key == model.currentModelKey { ProgressView().controlSize(.small) }
                        }
                        Text("\(m.engineName) · \(sizes[m.key].map { "\(Fmt.n($0 / 1e9, 1)) GB downloaded" } ?? "not downloaded yet: the first start fetches it") · \(m.repo)")
                            .outfit(12).foregroundStyle(pal.inkMuted).lineLimit(1).truncationMode(.middle)
                    }
                    .disabled(model.isWorking("model"))
                }
            }
            .padding(.top, 12)
            HStack {
                Button(adding ? "Cancel" : "Add a model…") { adding.toggle() }.buttonStyle(SecondaryButtonStyle(height: 32))
                Spacer()
            }
            .padding(.top, 4)
            if adding { addForm }
            Muted(text: "Switching restarts the model if it is loaded. TensorFold reads MLX builds only: 1.0 runs the exact Qwen3.5-2B and Qwen3.8-27B shapes it is qualified for; 0.6 also runs 9B Qwen3.5 MLX 4-bit builds (not qualified by the TensorFold project). GGUF files from LM Studio do not run here.", size: 12)
                .padding(.top, 12)

            CardTitle(text: "Memory").padding(.top, 22)
            Muted(text: "A loaded model holds several GB of unified memory. The endpoint stays up either way and loads the model when a request arrives.", size: 13)
                .padding(.top, 6).padding(.bottom, 10)
            VStack(spacing: 8) {
                modeRow("always", "Keep the model loaded", "Fastest replies; holds the memory the whole time.")
                modeRow("idle", "Unload when idle", "Frees the memory after a while without requests; the next request loads it again.")
                modeRow("ondemand", "Load on first request", "Nothing is loaded when the app opens; also unloads when idle.")
            }
            .disabled(model.isWorking("mode"))
            if model.memoryMode != "always" {
                HStack(spacing: 10) {
                    Text("Unload after").outfit(14).foregroundStyle(pal.inkSoft)
                    TextField("", text: $idleText).field().frame(width: 80)
                        .onSubmit { commitIdle() }
                    Text("minutes without a request").outfit(14).foregroundStyle(pal.inkSoft)
                    if Int(idleText) != model.idleMinutes {
                        Button("Save") { commitIdle() }.buttonStyle(SecondaryButtonStyle(height: 34))
                    }
                }
                .padding(.top, 8).padding(.leading, 4)
            }
        }
        .onAppear { idleText = String(model.idleMinutes); loadSizes() }
        .onChange(of: model.idleMinutes) { _, v in idleText = String(v) }
        .onChange(of: model.models) { _, _ in loadSizes() }
    }

    var addForm: some View {
        VStack(alignment: .leading, spacing: 10) {
            TextField("Hugging Face name, e.g. mlx-community/Qwen3.5-2B-MLX-4bit", text: $repo).field(mono: true)
            HStack(spacing: 12) {
                Segmented(options: [("tf06", "TensorFold 0.6"), ("native", "TensorFold 1.0")], selection: $engine, fill: false)
                Spacer()
                Button("Add") {
                    if let e = ModelEntry.add(repo: repo, engine: engine, label: "") {
                        model.toast(.warn, "Not added", e, seconds: 5)
                    } else {
                        model.toast(.success, "Model added", "Select it above to use it. The first start downloads it.", seconds: 5)
                        repo = ""; adding = false
                        model.reloadFiles(force: true)
                    }
                }
                .buttonStyle(PrimaryButtonStyle(height: 36))
                .disabled(repo.trimmingCharacters(in: .whitespaces).isEmpty)
            }
        }
        .padding(14)
        .background(RoundedRectangle(cornerRadius: 14).fill(pal.surface2))
        .padding(.top, 10)
    }

    func modeRow(_ key: String, _ title: String, _ sub: String) -> some View {
        RadioRow(selected: model.memoryMode == key, action: { model.setMode(key, minutes: Int(idleText)) }) {
            Text(title).outfit(14, .bold).foregroundStyle(pal.ink)
            Text(sub).outfit(12).foregroundStyle(pal.inkMuted)
        }
    }

    func commitIdle() {
        guard let n = Int(idleText.trimmingCharacters(in: .whitespaces)), n >= 1, n <= 1440 else {
            model.toast(.warn, "Minutes from 1 to 1440", "", seconds: 3)
            idleText = String(model.idleMinutes)
            return
        }
        model.setIdleMinutes(n)
    }

    func loadSizes() {
        let list = model.models
        DispatchQueue.global(qos: .utility).async {
            var out: [String: Double] = [:]
            for m in list { if let b = m.cachedBytes { out[m.key] = b } }
            DispatchQueue.main.async { sizes = out }
        }
    }
}

// MARK: - network

private struct NetworkCard: View {
    @EnvironmentObject var model: AppModel
    @Environment(\.pal) var pal

    var body: some View {
        let busy = model.isWorking("share")
        Card {
            CardTitle(text: "Network")
            ToggleRow(title: "Serve the model on the network",
                      sub: "Off: only this Mac (127.0.0.1). On: other computers on your network reach the same model over your LAN address, the way LM Studio's network server does. The endpoint restarts to apply it; a reply in progress is cut off.",
                      isOn: Binding(get: { model.share }, set: { model.setShare($0) }))
                .disabled(busy)
            if model.share {
                ToggleRow(title: "Require an API key",
                          sub: "Optional. Off: anyone who can reach this Mac can use the model. On: other computers must send the key below (Authorization: Bearer <key> or x-api-key). Requests from this Mac never need it.",
                          isOn: Binding(get: { model.requireKey }, set: { model.setRequireKey($0) }))
                    .disabled(busy)
                if model.requireKey {
                    HStack(spacing: 10) {
                        Text(model.apiKey.isEmpty ? "no key yet" : model.apiKey).font(Fonts.mono(13)).foregroundStyle(pal.inkSoft)
                            .textSelection(.enabled).lineLimit(1).truncationMode(.middle)
                            .padding(.horizontal, 12).frame(maxWidth: .infinity, minHeight: 38, alignment: .leading)
                            .background(RoundedRectangle(cornerRadius: 14).fill(pal.surface2))
                        Button("Generate") { model.generateKey() }.buttonStyle(SecondaryButtonStyle(height: 38)).disabled(busy)
                        IconButton(symbol: "doc.on.doc", help: "Copy the key", size: 38) {
                            Clip.copy(model.apiKey)
                            model.toast(.success, "Copied", "The key is on your clipboard.", seconds: 2)
                        }
                        .disabled(model.apiKey.isEmpty)
                    }
                    .padding(.top, 12)
                } else {
                    Text("No API key: anyone who can reach this Mac can use the model. A key is recommended beyond a trusted home network.")
                        .outfit(13).foregroundStyle(pal.warnText).padding(.top, 12)
                }
                let ips = Net.lanAddresses()
                VStack(alignment: .leading, spacing: 4) {
                    Muted(text: ips.isEmpty ? "From another computer: this Mac has no network address right now." : "From another computer (OpenAI base URL):", size: 13)
                    ForEach(ips, id: \.self) { CopyValue(value: "http://\($0):\(model.gatewayPort)/v1") }
                }
                .padding(.top, 12)
                Muted(text: "If macOS asks whether Python may accept incoming network connections, choose Allow (the endpoint runs on TensorFold 0.6's Python). Switch sharing off when you are done.")
                    .padding(.top, 10)
            }
        }
    }
}

// MARK: - options

private struct OptionsCard: View {
    @EnvironmentObject var model: AppModel
    @Environment(\.pal) var pal

    var body: some View {
        Card {
            CardTitle(text: "Options")
            ToggleRow(title: "Start TensorFold when this app opens", sub: "Starts the endpoint and loads the model (unless it loads on first request). Otherwise use Start on this page.",
                      isOn: $model.settings.autoStart)
            ToggleRow(title: "Open this app at login", sub: "Hidden, in the menu bar. Off by default.",
                      isOn: Binding(get: { model.openAtLogin }, set: { model.setOpenAtLogin($0) }))
            ToggleRow(title: "Keep the endpoint running from login",
                      sub: "So Hermes and other apps can always reach \(model.apiURL); it loads the model when a request arrives. It costs almost nothing while the model is unloaded.",
                      isOn: Binding(get: { model.endpointAtLogin }, set: { model.setEndpointAtLogin($0) }))
                .disabled(model.isWorking("login"))
            ToggleRow(title: "Unload the model when this app quits",
                      sub: "Gives the memory back when you quit. The endpoint stays if it runs from login, and loads the model again on the next request.",
                      isOn: $model.settings.freeOnQuit)
            HStack(spacing: 12) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Open WebUI").outfit(14, .medium).foregroundStyle(pal.inkSoft)
                    Muted(text: model.webuiRunning ? "Running at http://127.0.0.1:\(model.webuiPort), using the same endpoint." : "A browser chat on the same endpoint (optional). Stopped.")
                }
                Spacer()
                if model.webuiRunning {
                    Button("Stop") { model.stopWebUI() }.buttonStyle(SecondaryButtonStyle(height: 34))
                }
                Button(model.isWorking("webui") ? "Starting…" : "Open") { model.openWebUI() }.buttonStyle(SecondaryButtonStyle(height: 34))
                    .disabled(model.isWorking("webui"))
            }
            .padding(.top, 16)
            HStack(spacing: 12) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Command line").outfit(14, .medium).foregroundStyle(pal.inkSoft)
                    Muted(text: "tfctl status, tfctl use MODEL, tfctl endpoint, tfctl logs engine: the same controls in Terminal.")
                }
                Spacer()
                Button("Show files") { NSWorkspace.shared.activateFileViewerSelecting([Paths.configEnv]) }.buttonStyle(SecondaryButtonStyle(height: 34))
            }
            .padding(.top, 16)
        }
    }
}

// MARK: - updates

private struct UpdatesCard: View {
    @EnvironmentObject var model: AppModel
    @ObservedObject var engine: EngineUpdates
    @ObservedObject var app: SelfUpdater
    @Environment(\.pal) var pal

    var body: some View {
        Card {
            CardTitle(text: "TensorFold updates")
            ToggleRow(title: "Update TensorFold automatically",
                      sub: "Every day at \(String(format: "%02d:%02d", Int(model.config["UPDATE_HOUR"] ?? "4") ?? 4, Int(model.config["UPDATE_MINUTE"] ?? "30") ?? 30)) (or when the Mac next wakes): TensorFold 1.0 from Homebrew, TensorFold 0.6 from its python-0.6 branch, and Open WebUI. Each update is checked before it is kept; a failed one goes back to the version you had. A busy model is not restarted.",
                      isOn: Binding(get: { model.autoUpdateEngine }, set: { model.setAutoUpdateEngine($0) }))
            Text(engine.summary).outfit(13).foregroundStyle(pal.inkSoft).padding(.top, 16).fixedSize(horizontal: false, vertical: true)
            let comps = engine.report["components"].array
            if !comps.isEmpty {
                Grid(alignment: .leading, horizontalSpacing: 18, verticalSpacing: 6) {
                    ForEach(Array(comps.enumerated()), id: \.offset) { _, c in
                        GridRow {
                            Text(c["name"].str).outfit(13, .medium).foregroundStyle(pal.inkSoft)
                            Text(c["before"].str.isEmpty ? "–" : c["before"].str).font(Fonts.mono(12)).foregroundStyle(pal.inkMuted)
                            Text(c["status"].str == "current" ? "" : "→ \(c["after"].str)").font(Fonts.mono(12)).foregroundStyle(pal.inkMuted)
                            Badge(text: c["status"].str, tone: tone(c["status"].str))
                        }
                    }
                }
                .padding(.top, 10)
            }
            HStack(spacing: 10) {
                Button(engine.running == "check" ? "Checking…" : "Check now") { engine.check() }.buttonStyle(SecondaryButtonStyle())
                Button(engine.running == "update" ? "Updating…" : "Update now") { engine.updateNow() }.buttonStyle(PrimaryButtonStyle())
            }
            .disabled(engine.running != nil || !model.backendInstalled)
            .padding(.top, 14)
            Muted(text: "Checking runs brew update and asks GitHub and PyPI, so it takes a little while. Models and settings are kept.").padding(.top, 8)

            Rectangle().fill(pal.lineSoft).frame(height: 1).padding(.vertical, 22)

            CardTitle(text: "TensorFold Home updates")
            ToggleRow(title: "Check for TensorFold Home updates",
                      sub: "Checks this app's GitHub releases on startup and every six hours. A new version is downloaded only when you press Update, and goes in when the app quits.",
                      isOn: $model.settings.autoUpdateApp)
            Text(app.status).outfit(13).foregroundStyle(pal.inkSoft).padding(.top, 16).fixedSize(horizontal: false, vertical: true)
            HStack(spacing: 10) {
                Button(app.checking ? "Checking…" : "Check now") { app.checkNow() }.buttonStyle(SecondaryButtonStyle())
                    .disabled(app.checking || app.busy)
                Button(appButton) { app.staged ? NSApp.terminate(nil) : app.updateNow() }.buttonStyle(PrimaryButtonStyle())
                    .disabled(app.checking || app.busy || (!app.available && !app.staged && !app.latest.isEmpty))
            }
            .padding(.top, 14)
            Muted(text: "Version \(AppModel.version). The download's SHA-256 is checked against the one GitHub publishes for the release before anything is staged; the version you had is kept in ~/Library/Application Support/TensorFoldHome/updates/app-before-<version>.")
                .padding(.top, 8)
        }
    }

    var appButton: String {
        if app.busy { return "Downloading…" }
        if app.staged { return "Quit and install" }
        if app.available { return "Update TensorFold Home" }
        return app.latest.isEmpty ? "Update TensorFold Home" : "Up to date"
    }

    func tone(_ s: String) -> Tone {
        switch s {
        case "current", "not installed": return .muted
        case "updated": return .accent
        case "available": return .info
        default: return .warn
        }
    }
}

// MARK: - logs

private struct LogCard: View {
    @EnvironmentObject var model: AppModel
    @Environment(\.pal) var pal
    @State private var text = ""

    var body: some View {
        Card {
            HStack {
                CardTitle(text: "Logs")
                Spacer()
                Button("Open log folder") { NSWorkspace.shared.open(Paths.backendLogs) }.buttonStyle(SecondaryButtonStyle(height: 32))
            }
            Segmented(options: [("engine", "Engine"), ("gateway", "Endpoint"), ("update", "Updates"), ("webui", "Open WebUI"), ("app", "This app")],
                      selection: $model.settings.logSource)
                .padding(.top, 12)
            ScrollViewReader { proxy in
                ScrollView {
                    Text(text).font(Fonts.mono(11.5)).foregroundStyle(pal.codeInk)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .textSelection(.enabled)
                        .padding(14)
                    Color.clear.frame(height: 1).id("end")
                }
                .frame(height: 300)
                .background(RoundedRectangle(cornerRadius: 14).fill(pal.codeBg))
                .onChange(of: text) { _, _ in proxy.scrollTo("end", anchor: .bottom) }
            }
            .padding(.top, 12)
        }
        .task(id: model.settings.logSource) {
            while !Task.isCancelled {
                let t = model.logText(model.settings.logSource)
                if t != text { text = t }
                try? await Task.sleep(nanoseconds: 2_000_000_000)
            }
        }
    }
}
