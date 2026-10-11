import Foundation

/// The backend (engine launcher, endpoint gateway, updater, tfctl) ships inside the app in Resources/backend and is
/// installed to ~/Library/Application Support/TensorFoldLauncher. Settings there (config.env, models.conf) are kept.
@MainActor
final class BackendSetup: ObservableObject {
    struct Check {
        let name: String
        let ok: Bool
        let detail: String
        var optional = false
    }

    @Published var checks: [Check] = []
    @Published var running = false
    @Published var output = ""

    static var bundled: URL? {
        let u = Bundle.main.resourceURL?.appendingPathComponent("backend")
        return u.flatMap { FileManager.default.fileExists(atPath: $0.appendingPathComponent("bin/tfctl").path) ? $0 : nil }
    }

    init() { refresh() }

    var homebrew: Bool { FileManager.default.isExecutableFile(atPath: "/opt/homebrew/bin/brew") }
    var ready: Bool { checks.filter { !$0.optional }.allSatisfy(\.ok) }

    func refresh() {
        let fm = FileManager.default
        let b = Paths.backend
        let uv = ["/opt/homebrew/bin/uv", Paths.home.path + "/.local/bin/uv"].first { fm.isExecutableFile(atPath: $0) }
        checks = [
            Check(name: "Homebrew", ok: homebrew, detail: homebrew ? "/opt/homebrew" : "install it from brew.sh"),
            Check(name: "uv", ok: uv != nil, detail: uv ?? "Python environments (installed by Set up)"),
            Check(name: "TensorFold 1.0", ok: fm.isExecutableFile(atPath: "/opt/homebrew/bin/tensorfold"), detail: "Homebrew formula ashhart/tensorfold"),
            Check(name: "TensorFold 0.6", ok: fm.isExecutableFile(atPath: b.appendingPathComponent("venv-tf06/bin/tensorfold").path),
                  detail: "runs the 9B models and the endpoint"),
            Check(name: "Endpoint and tfctl", ok: fm.isExecutableFile(atPath: Paths.tfctl) && fm.fileExists(atPath: Paths.configEnv.path),
                  detail: b.path.replacingOccurrences(of: Paths.home.path, with: "~")),
            Check(name: "Open WebUI", ok: fm.isExecutableFile(atPath: b.appendingPathComponent("venv-webui/bin/open-webui").path),
                  detail: "optional browser chat", optional: true),
        ]
    }

    /// Copies the bundled scripts over the installed ones when this app's copy differs (new app version, or a first
    /// run on a Mac that ran the old launcher). Returns true when the endpoint gateway's code changed.
    @discardableResult
    static func syncBundled() -> Bool {
        guard let src = bundled else { return false }
        let fm = FileManager.default
        let stampFile = Paths.backend.appendingPathComponent("bin/.bundle-version")
        let stamp = (try? String(contentsOf: src.appendingPathComponent("VERSION"), encoding: .utf8))?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let installed = (try? String(contentsOf: stampFile, encoding: .utf8))?.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !stamp.isEmpty, stamp != installed else { return false }
        // only refresh an existing install here; a new Mac goes through Set up (it also installs the engines)
        guard fm.fileExists(atPath: Paths.backend.appendingPathComponent("bin").path) else { return false }
        var gatewayChanged = false
        for name in (try? fm.contentsOfDirectory(atPath: src.appendingPathComponent("bin").path)) ?? [] where !name.hasPrefix(".") {
            let from = src.appendingPathComponent("bin/\(name)"), to = Paths.backend.appendingPathComponent("bin/\(name)")
            if fm.contentsEqual(atPath: from.path, andPath: to.path) { continue }
            if name == "tf-gateway.py" { gatewayChanged = true }
            try? fm.removeItem(at: to)
            try? fm.copyItem(at: from, to: to)
            try? fm.setAttributes([.posixPermissions: name.hasSuffix(".sh") || name.hasSuffix("units.py") ? 0o644 : 0o755], ofItemAtPath: to.path)
        }
        for (file, def) in [("config.env", "config.env.default"), ("models.conf", "models.conf")] {
            let to = Paths.backend.appendingPathComponent(file)
            if !fm.fileExists(atPath: to.path) { try? fm.copyItem(at: src.appendingPathComponent(def), to: to) }
        }
        try? stamp.write(to: stampFile, atomically: true, encoding: .utf8)
        Paths.diag("backend scripts updated to \(stamp)" + (gatewayChanged ? " (gateway changed)" : ""))
        return gatewayChanged
    }

    /// Runs the bundled install.sh, showing its output as it goes.
    func install(webui: Bool, model: AppModel) {
        guard !running, let src = Self.bundled else {
            if Self.bundled == nil { model.toast(.error, "Set up is not available", "This build has no bundled backend.", seconds: 6) }
            return
        }
        running = true
        output = ""
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/bin/bash")
        p.arguments = [src.appendingPathComponent("install.sh").path] + (webui ? ["--webui"] : [])
        var env = ProcessInfo.processInfo.environment
        env["PATH"] = "/opt/homebrew/bin:\(Paths.home.path)/.local/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin"
        env["HOMEBREW_NO_AUTO_UPDATE"] = "1"
        p.environment = env
        let pipe = Pipe()
        p.standardOutput = pipe
        p.standardError = pipe
        pipe.fileHandleForReading.readabilityHandler = { h in
            let s = String(decoding: h.availableData, as: UTF8.self)
            guard !s.isEmpty else { return }
            DispatchQueue.main.async {
                self.output += s
                if self.output.count > 30_000 { self.output = String(self.output.suffix(20_000)) }
            }
        }
        p.terminationHandler = { proc in
            pipe.fileHandleForReading.readabilityHandler = nil
            DispatchQueue.main.async {
                self.running = false
                self.refresh()
                model.reloadFiles(force: true)
                Paths.diag("setup exited \(proc.terminationStatus)")
                if proc.terminationStatus == 0 {
                    model.toast(.success, "TensorFold is set up", "Press Start to load the model. The first start downloads it.", seconds: 8)
                } else {
                    model.toast(.error, "Set up stopped", "The output above says where. You can run it again.", seconds: 8)
                }
            }
        }
        do { try p.run() } catch {
            running = false
            output = "Could not run install.sh: \(error.localizedDescription)"
        }
    }
}
