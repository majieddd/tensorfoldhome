import AppKit
import SwiftUI

/// Context sizes: the presets, reading what someone types ("128K", "100,000", "1M") and labels.
enum ContextSize {
    static let presets = [16384, 32768, 65536, 131072, 262144, 524288, 1_048_576]
    static let minimum = 4096
    static let hermesFloor = 64000

    /// "128K" -> 131072 and "1M" -> 1048576 (K and M count in 1024s, like the presets), "100000" / "100,000" -> 100000.
    static func parse(_ text: String) -> Int? {
        var t = text.lowercased().filter { !" ,_".contains($0) }
        if t.hasSuffix("tokens") { t.removeLast(6) }
        var unit = 1.0
        if t.hasSuffix("k") { unit = 1024; t.removeLast() } else if t.hasSuffix("m") { unit = 1_048_576; t.removeLast() }
        guard let v = Double(t), v.isFinite, v > 0, v * unit < 1e9 else { return nil }
        return Int((v * unit).rounded())
    }

    static func label(_ n: Int) -> String {
        if n >= 1_048_576 && n % 1_048_576 == 0 { return "\(n / 1_048_576)M" }
        if n % 1024 == 0 { return "\(n / 1024)K" }
        return Fmt.n(Double(n))
    }

    /// The presets a model takes, plus the current size when it is not one of them.
    static func options(now: Int, max: Int) -> [Int] {
        var list = presets.filter { $0 <= max }
        if !list.contains(now) { list.append(now); list.sort() }
        return list
    }

    /// The smallest preset that holds `tokens` with a quarter to spare for the reply and the next turns.
    static func suggestion(for tokens: Int, max: Int) -> Int? {
        presets.first { $0 <= max && Double($0) >= Double(tokens) * 1.25 }
    }
}

enum MemoryFit { case comfortable, tight, tooBig }

struct ContextEstimate {
    let bytes: Double
    let budget: Double
    var fit: MemoryFit { bytes <= budget * 0.85 ? .comfortable : bytes <= budget ? .tight : .tooBig }
}

/// A context change in progress: the model reloading at the new size, which is undone if it does not load.
struct ContextChange: Equatable {
    let from: Int
    let to: Int
    let started: Date
}

extension AppModel {
    var modelInfo: J { status["model_info"] }
    /// The longest context the loaded model was built for (its RoPE table), else Qwen3.5's 256K.
    var maxContext: Int { modelInfo["max_context"].int ?? 262_144 }

    /// Whether the engine sets the window aside when the model loads; TensorFold grows it as a conversation fills.
    var reservesContext: Bool { modelInfo["reserves_context"].bool }
    /// TensorFold keeps no separate conversation slots; the estimate is for one conversation at a full window.
    var sessions: Int { 1 }

    /// The memory the model takes with every kept conversation filling the window: the loaded model (measured by the
    /// endpoint after the last load, else weights plus runtime) and the KV cache, 32 KB a token for a 9B Qwen3.5
    /// (TensorFold reports it at start). Nil until the endpoint has described the model.
    func memoryEstimate(context n: Int, sessions s: Int? = nil) -> ContextEstimate? {
        guard let kv = modelInfo["kv_bytes_per_token"].double, let budget = MacFacts.current.gpuBudget else { return nil }
        let base: Double
        if let b = modelInfo["base_bytes"].double { base = b }
        else if let w = modelInfo["weights_bytes"].double { base = w + (modelInfo["runtime_bytes"].double ?? (reservesContext ? 1.1e9 : 2.7e9)) }
        else { return nil }
        return ContextEstimate(bytes: base + kv * Double(n) * Double(max(1, s ?? sessions)), budget: budget)
    }

    /// The loaded model before any conversation.
    var loadedBaseBytes: Double? { modelInfo["base_bytes"].double }

    /// Requests that did not fit the current window (the endpoint counts them), with a size that would have held them.
    var overflowHint: (count: Int, largest: Int?, suggest: Int?)? {
        let o = status["overflows"]
        guard let count = o["count"].int, count > 0, o["largest_context"].int == context,
              let at = o["last_at"].double, Date().timeIntervalSince1970 - at < 14 * 86400 else { return nil }
        let largest = o["largest_estimate"].int
        return (count, largest, largest.flatMap { ContextSize.suggestion(for: $0, max: maxContext) })
    }

    /// The largest prompt plus reply among the recent requests the Monitor keeps.
    var largestRecentRequest: Int? {
        metrics["requests"].array.compactMap { r -> Int? in
            guard let p = r["prompt_tokens"].int else { return nil }
            return p + (r["output_tokens"].int ?? 0)
        }.max()
    }

    /// The last error the engine logged since it was last started, for a size that would not load.
    static func lastEngineError() -> String? {
        guard let text = try? String(contentsOf: Paths.backendLogs.appendingPathComponent("engine.log"), encoding: .utf8) else { return nil }
        let run = text.components(separatedBy: "tf-engine: ").last ?? text
        let lines = run.components(separatedBy: "\n").filter {
            let l = $0.lowercased()
            return (l.contains("error") || l.contains("panic") || l.contains("failed") || l.contains("memory")) && !l.contains("failed in ")
        }
        return lines.last.map { String($0.trimmingCharacters(in: .whitespaces).prefix(160)) }
    }

    /// Saves the size; with `reload`, reloads the model at it and watches it come up. A model that fails to load at the new
    /// size (too big for memory, usually) gets the previous size back and is reloaded at that.
    func changeContext(to n: Int, reload: Bool) {
        let old = context
        guard n != old, n >= ContextSize.minimum, contextChange == nil else { return }
        EnvFile(url: Paths.configEnv).set("CONTEXT", String(n))
        reloadFiles(force: true)
        log("context \(old) -> \(n)\(reload ? " (reloading)" : "")")
        let hermes = n < ContextSize.hermesFloor ? " Hermes needs at least 64,000 tokens." : " Hermes picks up the new size from the endpoint."
        guard reload, engineLoaded || runState == .loading else {
            toast(.success, "Context set to \(ContextSize.label(n))",
                  (engineLoaded ? "Used from the next load of the model." : "Used when the model next loads.") + hermes,
                  seconds: 8, action: engineLoaded ? "Reload now" : nil) { [weak self] in self?.reloadAtContext(from: old, to: n) }
            return
        }
        reloadAtContext(from: old, to: n)
    }

    func reloadAtContext(from old: Int, to n: Int) {
        guard contextChange == nil else { return }
        contextChange = ContextChange(from: old, to: n, started: Date())
        Task {
            let restarted = await tfctl("context", ["engine", "restart", "--no-wait"])
            var crashed = restarted.0 != 0
            if !crashed {
                try? await Task.sleep(nanoseconds: 2_000_000_000)
                var errors = 0
                let deadline = Date().addingTimeInterval(900)
                while Date() < deadline {
                    await refresh()
                    if engineLoaded {
                        contextChange = nil
                        let est = memoryEstimate(context: n).map { " About \(Fmt.n($0.bytes / 1e9, 1)) GB of memory." } ?? ""
                        toast(.success, "The context is \(ContextSize.label(n)) now", "\(Fmt.n(Double(n))) tokens.\(est)", seconds: 8)
                        log("context \(n) loaded")
                        return
                    }
                    // launchd restarts a crashed engine after 10 s; seeing it down with an error twice means it can't load
                    if status["engine"].str == "error" { errors += 1 } else { errors = 0 }
                    if errors >= 2 { crashed = true; break }
                    try? await Task.sleep(nanoseconds: 1_500_000_000)
                }
                if !crashed {
                    contextChange = nil
                    toast(.warn, "Still loading", "The model has not finished loading at \(ContextSize.label(n)) after 15 minutes. Check the Server log.", seconds: 12)
                    return
                }
            }
            let why = Self.lastEngineError() ?? "it did not start"
            log("context \(n) did not load (\(why)); back to \(old)")
            EnvFile(url: Paths.configEnv).set("CONTEXT", String(old))
            reloadFiles(force: true)
            contextChange = nil
            toast(.warn, "\(ContextSize.label(n)) did not load", "Back to \(ContextSize.label(old)), which is reloading. \(why)", seconds: 14)
            _ = await tfctl("context", ["engine", "restart", "--no-wait"])
            await refresh()
        }
    }
}

/// The context window control, on the Server tab under the model list and on the About tab.
struct ContextWindowEditor: View {
    @EnvironmentObject var model: AppModel
    @Environment(\.pal) var pal
    @State private var pick = 0
    @State private var custom = ""
    var showTitle = true

    var body: some View {
        let now = model.context
        let maxCtx = model.maxContext
        VStack(alignment: .leading, spacing: 0) {
            if showTitle {
                HStack(alignment: .firstTextBaseline) {
                    Text("Context window").outfit(16, .bold).foregroundStyle(pal.ink)
                    Spacer()
                    Text("now \(Fmt.n(Double(now))) tokens").outfit(12).foregroundStyle(pal.inkMuted)
                }
            }
            Muted(text: "How much one conversation can hold, prompt plus reply. " + (model.reservesContext
                    ? "The engine sets the whole window aside when the model loads, so a bigger window costs memory even before it fills."
                    : "TensorFold takes the memory as a conversation fills, so a bigger window costs nothing until a conversation gets that long.")
                  + " This model goes up to \(ContextSize.label(maxCtx)).", size: 12)
                .padding(.top, 4)
            if let hint = model.overflowHint { overflowBanner(hint) }
            Segmented(options: ContextSize.options(now: now, max: maxCtx).map { ($0, ContextSize.label($0)) }, selection: $pick, fill: false)
                .padding(.top, 12)
            HStack(spacing: 10) {
                Text("Or type a size").outfit(13, .medium).foregroundStyle(pal.inkSoft)
                TextField("e.g. 96K or 100000", text: $custom).field(mono: true).frame(width: 170)
                    .onSubmit { if let v = customValue { pick = v } }
                    .onChange(of: custom) { _, _ in if let v = customValue { pick = v } }
                Text(customFeedback).outfit(12).foregroundStyle(customValue == nil && !custom.isEmpty ? pal.dangerText : pal.inkMuted)
            }
            .padding(.top, 12)
            if pick > 0 { estimateRow(pick, now: now) }
            if let change = model.contextChange {
                HStack(spacing: 8) {
                    ProgressView().controlSize(.small)
                    TimelineView(.periodic(from: change.started, by: 1)) { ctx in
                        Text("Reloading the model at \(ContextSize.label(change.to)) · \(Int(ctx.date.timeIntervalSince(change.started))) s. If it does not load, \(ContextSize.label(change.from)) comes back by itself.")
                            .outfit(12).foregroundStyle(pal.inkSoft)
                    }
                }
                .padding(.top, 12)
            } else {
                HStack(spacing: 10) {
                    Button(model.engineLoaded ? "Apply and reload the model" : "Apply") { model.changeContext(to: pick, reload: true) }
                        .buttonStyle(PrimaryButtonStyle(height: 36))
                    if model.engineLoaded {
                        Button("Save for the next load") { model.changeContext(to: pick, reload: false) }
                            .buttonStyle(SecondaryButtonStyle(height: 36))
                    }
                }
                .disabled(pick == now || pick < ContextSize.minimum || pick > maxCtx)
                .padding(.top, 14)
            }
        }
        .onAppear { pick = now }
        .onChange(of: now) { _, v in pick = v; custom = "" }
    }

    var customValue: Int? {
        guard let v = ContextSize.parse(custom), v >= ContextSize.minimum, v <= model.maxContext else { return nil }
        return v
    }

    var customFeedback: String {
        guard !custom.isEmpty else { return "" }
        guard let v = ContextSize.parse(custom) else { return "Type a number of tokens, like 100000 or 96K." }
        if v < ContextSize.minimum { return "At least \(Fmt.n(Double(ContextSize.minimum))) tokens." }
        if v > model.maxContext { return "This model goes up to \(Fmt.n(Double(model.maxContext))) tokens." }
        return "= \(Fmt.n(Double(v))) tokens"
    }

    @ViewBuilder
    func estimateRow(_ n: Int, now: Int) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            if let e = model.memoryEstimate(context: n) {
                let gb = Fmt.n(e.bytes / 1e9, 1), budget = Fmt.n(e.budget / 1e9, 1)
                let who = model.sessions > 1 ? "with \(model.sessions) conversations kept" : "with one conversation"
                let when = model.reservesContext ? "About \(gb) GB of memory \(who)"
                    : "Up to about \(gb) GB when \(model.sessions > 1 ? "every kept conversation fills" : "the conversation fills") the window"
                    + (model.loadedBaseBytes.map { " (it loads with about \(Fmt.n($0 / 1e9, 1)) GB)" } ?? "")
                switch e.fit {
                case .comfortable:
                    line("\(when). This Mac's GPU can use \(budget) GB.", .accent)
                case .tight:
                    line("\(when), close to the \(budget) GB this Mac's GPU can use. Other apps may get slower.", .warn)
                case .tooBig:
                    line(model.reservesContext
                         ? "\(when): more than the \(budget) GB this Mac's GPU can use, so it will most likely not load."
                         : "\(when): more than the \(budget) GB this Mac's GPU can use. It loads, but a conversation that long would fail or slow the Mac to a crawl.", .danger)
                }
                if e.fit != .comfortable, model.sessions > 1, let one = model.memoryEstimate(context: n, sessions: 1), one.fit != .tooBig {
                    line("With one conversation kept (About tab) it would take about \(Fmt.n(one.bytes / 1e9, 1)) GB.", .muted)
                }
            }
            if n < ContextSize.hermesFloor { line("Hermes refuses endpoints under 64,000 tokens.", .warn) }
            if let big = model.largestRecentRequest {
                line("The largest recent request took \(Fmt.n(Double(big))) tokens (\(Int(100 * Double(big) / Double(now)))% of the current \(ContextSize.label(now))).", .muted)
            }
        }
        .padding(.top, 10)
    }

    func line(_ text: String, _ tone: Tone) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            Circle().fill(pal.tone(tone)).frame(width: 6, height: 6)
            Text(text).outfit(12).foregroundStyle(tone == .muted ? pal.inkMuted : pal.toneText(tone)).fixedSize(horizontal: false, vertical: true)
        }
    }

    func overflowBanner(_ hint: (count: Int, largest: Int?, suggest: Int?)) -> some View {
        HStack(alignment: .center, spacing: 12) {
            Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(pal.warn)
            VStack(alignment: .leading, spacing: 2) {
                Text("\(hint.count) request\(hint.count == 1 ? "" : "s") did not fit in \(ContextSize.label(model.context))")
                    .outfit(13, .bold).foregroundStyle(pal.warnText)
                Text(hint.largest.map { "The largest was about \(Fmt.n(Double($0))) tokens. The endpoint answered with context_length_exceeded, which tells Hermes to compress the conversation." }
                     ?? "The endpoint answered with context_length_exceeded, which tells Hermes to compress the conversation.")
                    .outfit(12).foregroundStyle(pal.inkSoft).fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 0)
            if let s = hint.suggest, s != model.context {
                Button("Use \(ContextSize.label(s))") { pick = s }.buttonStyle(SecondaryButtonStyle(height: 32))
            }
        }
        .padding(12)
        .background(RoundedRectangle(cornerRadius: 14).fill(pal.warnTint))
        .padding(.top, 12)
    }
}
