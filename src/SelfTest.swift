import Foundation

/// `--selftest`: offline checks of the app's own logic (Markdown, versions, the SHA-256 gate, config files,
/// attachments, run states, this Mac's meters), plus a read-only look at the live endpoint when one is running.
/// Writes logs/selftest.txt; exit code 0 means everything passed. The endpoint itself is tested by tools/test_gateway.py.
@MainActor
enum SelfTest {
    static func run() -> Int32 {
        var lines: [String] = []
        var failed = 0
        func check(_ name: String, _ ok: Bool, _ detail: String = "") {
            lines.append("\(ok ? "PASS" : "FAIL")  \(name)\(detail.isEmpty ? "" : "  (\(detail))")")
            if !ok { failed += 1 }
        }
        let tmp = FileManager.default.temporaryDirectory.appendingPathComponent("tfh-selftest-\(UUID().uuidString.prefix(8))")
        try? FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tmp) }

        // Markdown
        let md = """
        # Title
        Some **bold** and `code`.

        - one
        - two
          continued
        1. first
        2) second

        > quoted

        | a | b |
        |---|--:|
        | 1 | 2 |

        ---
        ```swift
        let x = 1
        ```
        """
        let blocks = Markdown.parse(md)
        let kinds = blocks.map { b -> String in
            switch b {
            case .heading: return "h"
            case .paragraph: return "p"
            case .code: return "code"
            case .list: return "list"
            case .quote: return "quote"
            case .table: return "table"
            case .rule: return "rule"
            }
        }
        check("markdown block kinds", kinds == ["h", "p", "list", "quote", "table", "rule", "code"], kinds.joined(separator: ","))
        if case .list(let items) = blocks[2] {
            check("markdown list items, continuation and numbering", items.count == 4 && items[1].text == "two\ncontinued" && items[3].marker == "2.",
                  items.map(\.text).joined(separator: "|"))
        } else { check("markdown list", false) }
        if case .table(let h, let a, let rows) = blocks[4] {
            check("markdown table", h == ["a", "b"] && a.count == 2 && rows == [["1", "2"]])
        } else { check("markdown table", false) }
        if case .code(let lang, let text) = Markdown.parse("Here:\n```py\nprint(1)\nprint(2)").last {
            check("an unclosed fence (still streaming) is code", lang == "py" && text == "print(1)\nprint(2)")
        } else { check("an unclosed fence is code", false) }
        check("plain text is one paragraph", Markdown.parse("line one\nline two") == [.paragraph("line one\nline two")])

        // versions
        check("version compare", SelfUpdater.compare("0.2.0", "0.1.9") == 1 && SelfUpdater.compare("v0.1", "0.1.0") == 0
              && SelfUpdater.compare("0.10.0", "0.9.9") == 1 && SelfUpdater.compare("0.1.0", "0.1.1") == -1)
        check("tag normalize", SelfUpdater.normalize("v1.2.3") == "1.2.3" && SelfUpdater.normalize(" 0.4 ") == "0.4")

        // SHA-256 gate
        let file = tmp.appendingPathComponent("blob.bin")
        try? Data("TensorFold Home".utf8).write(to: file)
        let digest = SelfUpdater.sha256(file) ?? ""
        check("sha256 of a known string", digest == "ca15b9f4d97c5d1422f6e3d09f63a9cb6163e052100438d5c93ccbf5298929ae", digest)
        check("sha256 gate accepts the published digest", SelfUpdater.verify(file, expected: digest) == nil)
        check("sha256 gate accepts upper-case digests", SelfUpdater.verify(file, expected: digest.uppercased()) == nil)
        check("sha256 gate refuses a mismatch", SelfUpdater.verify(file, expected: String(repeating: "0", count: 64))?.contains("Nothing was staged") == true)
        check("sha256 gate refuses a release without a digest", SelfUpdater.verify(file, expected: "")?.contains("cannot be verified") == true)

        // config.env
        let env = EnvFile(url: tmp.appendingPathComponent("config.env"))
        try? "# comment\nMODEL=a  # trailing\nCONTEXT=65536\n".write(to: env.url, atomically: true, encoding: .utf8)
        env.set("CONTEXT", "131072")
        env.set("NEW_KEY", "1")
        let cfg = env.read()
        check("config.env read and set", cfg["MODEL"] == "a" && cfg["CONTEXT"] == "131072" && cfg["NEW_KEY"] == "1",
              cfg.map { "\($0.key)=\($0.value)" }.sorted().joined(separator: " "))
        check("config.env keeps comments", ((try? String(contentsOf: env.url, encoding: .utf8)) ?? "").hasPrefix("# comment\n"))

        // models.conf
        let conf = tmp.appendingPathComponent("models.conf")
        try? "# key|label|engine|repo\nqwen|Qwen|native|mlx-community/Qwen3.5-2B-MLX-4bit".write(to: conf, atomically: true, encoding: .utf8)
        check("models.conf parse", ModelEntry.load(conf).map(\.key) == ["qwen"])
        check("add a model", ModelEntry.add(repo: "someone/Some-9B-MLX-4bit", engine: "tf06", label: "", conf: conf) == nil
              && ModelEntry.load(conf).last?.key == "some-9b-mlx-4bit")
        check("adding the same model twice is refused", ModelEntry.add(repo: "someone/Some-9B-MLX-4bit", engine: "tf06", label: "", conf: conf) != nil)
        check("a bad repo name is refused", ModelEntry.add(repo: "not a repo", engine: "tf06", label: "", conf: conf) != nil)

        // chat: attachments are fenced with more backticks than they contain
        let model = AppModel()
        let chat = ChatModel(model: model)
        chat.messages = [ChatMsg(role: "user", text: "look", files: [Attachment(name: "a.md", text: "```\ncode\n```")])]
        let content = chat.apiMessages().first?["content"] as? String ?? ""
        check("attachment fence is longer than the file's own", content.contains("File: a.md\n````\n```\ncode\n```\n````"), content)
        chat.messages.append(ChatMsg(role: "assistant", text: "", error: "boom"))
        check("failed answers are not sent back", chat.apiMessages().count == 1)
        check("markdown export", chat.markdownExport().hasPrefix("## You\n\nlook"))

        // run states from the gateway's status
        model.gatewayUp = true
        model.polled = true
        for (engine, want) in [("running", RunState.ready), ("loading", .loading), ("stopped", .unloaded), ("error", .error)] {
            model.status = J(["engine": engine])
            check("engine \"\(engine)\" shows as \(want.title)", model.runState == want)
        }
        model.gatewayUp = false
        check("no endpoint shows as Stopped", model.runState == .stopped)
        model.gatewayUp = true
        model.status = J(["engine": "running"])
        model.metrics = J(["live": ["state": "generating", "tok_s": 24.5, "queued": 0]])
        check("pill while generating", model.pill.text == "Generating · 24.5 tok/s", model.pill.text)
        model.metrics = J(["live": ["state": "idle", "queued": 2]])
        check("pill while queued", model.pill.text == "2 queued", model.pill.text)

        // this Mac
        let mon = HardwareMonitor()
        _ = mon.sample(enginePid: nil)
        Thread.sleep(forTimeInterval: 0.5)   // CPU and disk rates need two samples apart
        let s = mon.sample(enginePid: Int(ProcessInfo.processInfo.processIdentifier))
        check("memory reading", (s.memTotal ?? 0) > 1e9 && (s.memUsed ?? 0) > 0, Fmt.gb(s.memUsed) + " / " + Fmt.gb(s.memTotal) + " GB")
        check("CPU reading", s.cpu != nil, Fmt.n(s.cpu, 1) + "%")
        if s.gpuUtil != nil {
            check("GPU reading", true, "\(Fmt.n(s.gpuUtil))%, \(MacFacts.current.gpuCores.map(String.init) ?? "?") cores")
        } else {
            lines.append("SKIP  GPU reading (this Mac reports no IOAccelerator statistics; virtual machines often don't)")
        }
        check("process footprint reading", (s.engineFootprint ?? 0) > 1_000_000, Fmt.n((s.engineFootprint ?? 0) / 1e6) + " MB")
        check("Mac facts", !MacFacts.current.chip.isEmpty && MacFacts.current.memory > 0, MacFacts.current.chip)

        // the live endpoint, read-only, when one is running
        let port = Int(EnvFile(url: Paths.configEnv).read()["GATEWAY_PORT"] ?? "") ?? 8484
        let sem = DispatchSemaphore(value: 0)
        var live: J?
        Task.detached {
            live = await HTTP.json("http://127.0.0.1:\(port)/tf/status", timeout: 3)
            sem.signal()
        }
        while sem.wait(timeout: .now() + 0.05) == .timedOut { RunLoop.main.run(until: Date().addingTimeInterval(0.05)) }
        if let live {
            check("live endpoint answers /tf/status", live["gateway"].str == "ok", "engine \(live["engine"].str), model \(live["model"]["key"].str)")
        } else {
            lines.append("SKIP  live endpoint (not running on :\(port))")
        }

        let summary = "\(lines.filter { $0.hasPrefix("PASS") }.count) passed, \(failed) failed"
        lines.append(summary)
        let text = "TensorFold Home \(AppModel.version) self-test, \(ISO8601DateFormatter().string(from: Date()))\n" + lines.joined(separator: "\n") + "\n"
        print(text, terminator: "")
        Paths.ensure()
        try? text.write(to: Paths.logs.appendingPathComponent("selftest.txt"), atomically: true, encoding: .utf8)
        return failed == 0 ? 0 : 1
    }
}
