import Foundation

/// The app's own settings (the backend's live in config.env, which `tfctl` owns). Kept in
/// ~/Library/Application Support/TensorFoldHome/settings.json.
struct Settings: Codable, Equatable {
    var theme = "system"            // system | light | dark
    var effort = "none"             // thinking: none | low | medium | high (TensorFold Home starts with it off: faster)
    var temperature = 0.0           // 0 = greedy, the engine's exact mode
    var topP = 0.95
    var topK = 20
    var maxTokens = ""              // empty = until done
    var seed = ""                   // empty = random
    var showThinking = true
    var autoStart = true            // start the endpoint (and load the model unless "load on first request") when the app opens
    var freeOnQuit = true           // unload the model when the app quits; the endpoint stays for Hermes
    var autoUpdateApp = true        // TensorFold Home's own releases, checked on startup and every six hours
    var logSource = "engine"        // Server log: engine | gateway | update | webui | app

    static var url: URL { Paths.app.appendingPathComponent("settings.json") }

    static func load() -> Settings {
        guard let data = try? Data(contentsOf: url) else { return Settings() }
        return (try? JSONDecoder().decode(Settings.self, from: data)) ?? Settings()
    }

    func save() {
        Paths.ensure()
        let enc = JSONEncoder()
        enc.outputFormatting = [.prettyPrinted, .sortedKeys]
        if let data = try? enc.encode(self) { try? data.write(to: Settings.url, options: .atomic) }
    }

    init() {}

    // Missing keys keep their defaults, so a settings file from an older version still loads.
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let d = Settings()
        theme = (try? c.decode(String.self, forKey: .theme)) ?? d.theme
        effort = (try? c.decode(String.self, forKey: .effort)) ?? d.effort
        temperature = (try? c.decode(Double.self, forKey: .temperature)) ?? d.temperature
        topP = (try? c.decode(Double.self, forKey: .topP)) ?? d.topP
        topK = (try? c.decode(Int.self, forKey: .topK)) ?? d.topK
        maxTokens = (try? c.decode(String.self, forKey: .maxTokens)) ?? d.maxTokens
        seed = (try? c.decode(String.self, forKey: .seed)) ?? d.seed
        showThinking = (try? c.decode(Bool.self, forKey: .showThinking)) ?? d.showThinking
        autoStart = (try? c.decode(Bool.self, forKey: .autoStart)) ?? d.autoStart
        freeOnQuit = (try? c.decode(Bool.self, forKey: .freeOnQuit)) ?? d.freeOnQuit
        autoUpdateApp = (try? c.decode(Bool.self, forKey: .autoUpdateApp)) ?? d.autoUpdateApp
        logSource = (try? c.decode(String.self, forKey: .logSource)) ?? d.logSource
    }
}

/// One line of models.conf: key|label|engine|Hugging Face repo.
struct ModelEntry: Identifiable, Equatable {
    let key, label, engine, repo: String
    var id: String { key }

    var engineName: String {
        switch engine {
        case "native": return "TensorFold 1.0 (native)"
        case "tf06": return "TensorFold 0.6 (Python/MLX)"
        default: return engine
        }
    }

    static func load(_ conf: URL = Paths.modelsConf) -> [ModelEntry] {
        guard let text = try? String(contentsOf: conf, encoding: .utf8) else { return [] }
        return text.split(separator: "\n").compactMap { raw in
            let line = raw.trimmingCharacters(in: .whitespaces)
            guard !line.isEmpty, !line.hasPrefix("#") else { return nil }
            let p = line.components(separatedBy: "|") + ["", "", ""]
            return p[0].isEmpty ? nil : ModelEntry(key: p[0], label: p[1].isEmpty ? p[0] : p[1], engine: p[2], repo: p[3])
        }
    }

    /// Size of the downloaded checkpoint in the Hugging Face cache, or nil when it is not there yet.
    var cachedBytes: Double? {
        let base = Paths.home.appendingPathComponent(".cache/huggingface/hub/models--\(repo.replacingOccurrences(of: "/", with: "--"))/snapshots")
        let fm = FileManager.default
        guard let snaps = try? fm.contentsOfDirectory(atPath: base.path).sorted(), let snap = snaps.last else { return nil }
        let dir = base.appendingPathComponent(snap)
        var total = 0.0
        for name in (try? fm.contentsOfDirectory(atPath: dir.path)) ?? [] {
            let path = dir.appendingPathComponent(name).resolvingSymlinksInPath().path
            total += Double((try? fm.attributesOfItem(atPath: path)[.size] as? Int) ?? 0)
        }
        return total > 0 ? total : nil
    }

    /// Adds a line to models.conf. Returns an error message, or nil.
    static func add(repo: String, engine: String, label: String, conf: URL = Paths.modelsConf) -> String? {
        let repo = repo.trimmingCharacters(in: .whitespaces)
        guard repo.range(of: #"^[A-Za-z0-9_.\-]+/[A-Za-z0-9_.\-]+$"#, options: .regularExpression) != nil else {
            return "Use the Hugging Face name, like mlx-community/Qwen3.5-2B-MLX-4bit."
        }
        let existing = load(conf)
        if existing.contains(where: { $0.repo.lowercased() == repo.lowercased() }) { return "That model is already in the list." }
        var key = repo.split(separator: "/").last.map(String.init)?.lowercased() ?? repo
        key = key.replacingOccurrences(of: #"[^a-z0-9.\-]+"#, with: "-", options: .regularExpression)
        while existing.contains(where: { $0.key == key }) { key += "-2" }
        let name = label.trimmingCharacters(in: .whitespaces).isEmpty ? repo.split(separator: "/").last.map(String.init) ?? repo : label
        let line = "\(key)|\(name.replacingOccurrences(of: "|", with: "/"))|\(engine)|\(repo)\n"
        guard let h = try? FileHandle(forWritingTo: conf) else { return "models.conf could not be opened." }
        h.seekToEndOfFile()
        if let data = try? Data(contentsOf: conf), let last = data.last, last != 0x0A { h.write(Data("\n".utf8)) }
        h.write(Data(line.utf8))
        try? h.close()
        return nil
    }
}
