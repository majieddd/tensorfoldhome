import SwiftUI

/// The Monitor tab: StrataHome's live meters, with the NVIDIA tiles swapped for what an Apple-silicon Mac reports
/// (GPU load and memory from IOAccelerator, unified memory, the engine's own footprint, thermal state) and
/// TensorFold's drafts in place of experts and PCIe.
struct MonitorView: View {
    @EnvironmentObject var model: AppModel
    @Environment(\.pal) var pal

    var body: some View {
        GeometryReader { g in
            let wide = g.size.width >= 1000
            ScrollView {
                VStack(spacing: 20) {
                    StateCard()
                    LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 16), count: wide ? 4 : 2), spacing: 16) {
                        Tiles()
                    }
                    if wide {
                        HStack(alignment: .top, spacing: 16) {
                            ContextCard().frame(width: (g.size.width - 48 - 16) / 3.4)
                            RequestsCard()
                        }
                    } else {
                        ContextCard()
                        RequestsCard()
                    }
                    CacheCard()
                    PerfCard()
                }
                .frame(maxWidth: 1240)
                .padding(24)
                .frame(maxWidth: .infinity)
            }
        }
    }
}

// MARK: - model state

private struct StateCard: View {
    @EnvironmentObject var model: AppModel
    @Environment(\.pal) var pal

    var body: some View {
        let live = model.metrics["live"]
        let last = model.metrics["requests"][0]
        let state = model.runState == .error ? "error" : (live["queued"].double ?? 0) > 0 ? "queued" : live["state"].string ?? "idle"
        let (label, detail, tone, busy) = describe(state, live, last)
        Card {
            HStack(spacing: 8) {
                CardTitle(text: "Model state").padding(.trailing, 8)
                ForEach([("idle", "Idle", Tone.muted), ("loading", "Loading", .warn), ("reading", "Reading", .info),
                         ("generating", "Generating", .accent), ("queued", "Queued", .warn), ("error", "Error", .danger)], id: \.0) { b in
                    Badge(text: b.1, tone: b.2).opacity(b.0 == state ? 1 : 0.38)
                }
                Spacer(minLength: 0)
            }
            HStack {
                Text(label).outfit(13, .medium).foregroundStyle(pal.ink)
                Spacer()
                Text(detail).outfit(13, .medium).foregroundStyle(pal.inkMuted)
            }
            .padding(.vertical, 12)
            BarView(fraction: 0, tone: tone, indeterminate: busy).id(state)
        }
    }

    func describe(_ state: String, _ live: J, _ last: J) -> (String, String, Tone, Bool) {
        switch state {
        case "loading": return ("Loading the model", "the request waits for it", .warn, true)
        case "reading": return ("Reading prompt", "\(Fmt.n(live["elapsed_s"].double, 1)) s", .info, true)
        case "generating":
            return ("Generating", "\(Fmt.n(live["generated"].double)) tokens · \(Fmt.n(live["tok_s"].double, 1)) tok/s", .accent, true)
        case "queued": return ("Queued", "\(Fmt.n(live["queued"].double)) waiting for a free lane", .warn, true)
        case "error": return ("The engine stopped with an error", "see the Server log", .danger, false)
        default:
            let what: String
            switch model.runState {
            case .stopped: what = model.polled ? "TensorFold is not running" : "Connecting…"
            case .unloaded: what = "Model unloaded · the next request loads it"
            default: what = "Waiting for a request"
            }
            if last.isNull { return (what, "", .accent, false) }
            let ts = last["decode_tok_s"].double
            return (what, "last: \(Fmt.n(last["output_tokens"].double)) tokens" + (ts.map { " at \(Fmt.n($0, 1)) tok/s" } ?? ""), .accent, false)
        }
    }
}

// MARK: - the eight tiles

private struct Tile: View {
    @Environment(\.pal) var pal
    let label: String
    let symbol: String
    var value: String?
    var unit = ""
    var sub = ""
    var value2: String? = nil
    var unit2 = ""
    var sub2 = ""
    var two = false
    var spark: [Double] = []
    var spark2: [Double] = []
    var sparkMax: Double = 0
    var tone: Tone = .accent

    var body: some View {
        Card(padding: 20) {
            HStack(spacing: 8) {
                Image(systemName: symbol).font(.system(size: 13, weight: .medium)).foregroundStyle(pal.inkMuted).frame(width: 18)
                Text(label).outfit(13, .medium).foregroundStyle(pal.inkMuted)
            }
            HStack(alignment: .top) {
                valueBlock(value, unit, sub)
                if two { Spacer(); valueBlock(value2, unit2, sub2, trailing: true) }
            }
            .padding(.top, 10)
            Sparkline(values: spark, second: spark2, maxValue: sparkMax, tone: tone).padding(.top, 10)
        }
    }

    func valueBlock(_ v: String?, _ u: String, _ s: String, trailing: Bool = false) -> some View {
        VStack(alignment: trailing ? .trailing : .leading, spacing: 10) {
            HStack(alignment: .lastTextBaseline, spacing: 4) {
                Text(v ?? "–").outfit(30, .black).foregroundStyle(pal.ink).lineLimit(1).minimumScaleFactor(0.6)
                if v != nil && !u.isEmpty { Text(u).outfit(14, .medium).foregroundStyle(pal.inkMuted) }
            }
            Text(s.isEmpty ? " " : s).outfit(12).foregroundStyle(pal.inkMuted).lineLimit(1).truncationMode(.tail)
        }
    }
}

private struct Tiles: View {
    @EnvironmentObject var model: AppModel
    let facts = MacFacts.current

    var body: some View {
        let m = model.metrics, live = m["live"], last = m["requests"][0], hist = m["history"], hw = model.hw
        let generating = live["state"].str == "generating"
        let speed = generating ? live["tok_s"].double : last["decode_tok_s"].double
        let prefill = last["prefill_tok_s"].double
        let facts2 = m["engine"]["facts"]
        let budget = facts2["memory_budget_gib"].double.map { $0 * 1_073_741_824 }

        Tile(label: "Speed", symbol: "speedometer",
             value: speed.map { Fmt.n($0, 1) }, unit: "t/s", sub: generating ? "Decode now" : last.isNull ? "Decode" : "Decode last request",
             value2: prefill.map { Fmt.n($0) }, unit2: "t/s", sub2: last.isNull ? "Prefill" : "Prefill last request", two: true,
             spark: hist["tok_s"].doubles)

        Tile(label: "GPU load", symbol: "cpu", value: hw.gpuUtil.map { Fmt.n($0) }, unit: "%",
             sub: "\(facts.chip)" + (facts.gpuCores.map { " · \($0)-core GPU" } ?? ""),
             spark: model.hwHistory["gpu"] ?? [], sparkMax: 100)

        Tile(label: "Memory", symbol: "memorychip", value: hw.memUsed.map { Fmt.gb($0) }, unit: "/ \(Fmt.gb(hw.memTotal, 0)) GB",
             sub: pressureText(hw.pressure) + (hw.gpuMem.map { " · GPU has \(Fmt.gb($0)) GB" } ?? ""),
             spark: model.hwHistory["mem"] ?? [], sparkMax: hw.memTotal ?? 0, tone: (hw.pressure ?? 1) > 1 ? .warn : .accent)

        Tile(label: "Model memory", symbol: "square.stack.3d.up", value: hw.engineFootprint.map { Fmt.gb($0) }, unit: "GB",
             sub: model.engineLoaded ? [facts2["weights_gib"].double.map { "weights \(Fmt.n($0, 1)) GiB" },
                                       budget.map { "budget \(Fmt.gb($0)) GB" }].compactMap { $0 }.joined(separator: " · ")
                                     : "not loaded",
             spark: model.hwHistory["engine"] ?? [], sparkMax: hw.memTotal ?? 0)

        let drafted = last["drafted"].double ?? 0, accepted = last["accepted"].double ?? 0
        Tile(label: "Drafts kept", symbol: "doc.on.doc", value: drafted > 0 ? Fmt.n(100 * accepted / drafted) : nil, unit: "%",
             sub: drafted > 0 ? "\(Fmt.n(accepted)) of \(Fmt.n(drafted)) drafted tokens, last request" : "when a reply repeats the prompt",
             spark: draftSeries(m["requests"].array), sparkMax: 100, tone: .info)

        Tile(label: "Thermal", symbol: "thermometer.medium", value: thermalText(hw.thermal), sub: "macOS thermal state",
             spark: model.hwHistory["thermal"] ?? [], sparkMax: 3, tone: .warn)

        Tile(label: "CPU", symbol: "gauge.with.dots.needle.33percent", value: hw.cpu.map { Fmt.n($0) }, unit: "%", sub: facts.coresText,
             spark: model.hwHistory["cpu"] ?? [], sparkMax: 100)

        Tile(label: "Disk read", symbol: "internaldrive", value: hw.diskRead.map { $0 >= 1000 ? Fmt.n($0 / 1024, 2) : Fmt.n($0, $0 < 10 ? 1 : 0) },
             unit: (hw.diskRead ?? 0) >= 1000 ? "GB/s" : "MB/s", sub: hw.diskWrite.map { "write \(Fmt.n($0, 1)) MB/s" } ?? "",
             spark: model.hwHistory["disk"] ?? [], tone: .info)
    }

    func draftSeries(_ reqs: [J]) -> [Double] {
        reqs.prefix(40).reversed().compactMap { r in
            guard let d = r["drafted"].double, d > 0 else { return nil }
            return 100 * (r["accepted"].double ?? 0) / d
        }
    }
}

func pressureText(_ p: Int?) -> String {
    switch p {
    case 2: return "memory pressure: warning"
    case 4: return "memory pressure: critical"
    case nil: return ""
    default: return "memory pressure: normal"
    }
}

func thermalText(_ t: Int) -> String { ["Nominal", "Fair", "Serious", "Critical"][max(0, min(3, t))] }

// MARK: - context fill

private struct ContextCard: View {
    @EnvironmentObject var model: AppModel
    @Environment(\.pal) var pal

    var body: some View {
        let ctx = model.metrics["engine"]["max_context"].double ?? Double(model.context)
        let last = model.metrics["requests"][0]
        let used = (last["prompt_tokens"].double ?? 0) + (last["output_tokens"].double ?? 0)
        let frac = ctx > 0 ? min(1, used / ctx) : 0
        let hw = model.hw
        let budget = model.metrics["engine"]["facts"]["memory_budget_gib"].double.map { $0 * 1_073_741_824 }
        Card {
            CardTitle(text: "Context fill")
            ZStack {
                Gauge270(fraction: frac).frame(width: 150, height: 150)
                VStack(spacing: 2) {
                    Text("\(Int((frac * 100).rounded()))%").outfit(24, .black).foregroundStyle(pal.ink)
                    Text(last.isNull ? "–" : "\(Fmt.k(used)) / \(Fmt.k(ctx))").outfit(12).foregroundStyle(pal.inkMuted)
                }
            }
            .frame(maxWidth: .infinity)
            .padding(.top, 8).padding(.bottom, 4)
            Text(last.isNull ? "No request yet" : "last request").outfit(12).foregroundStyle(pal.inkMuted).frame(maxWidth: .infinity)
                .padding(.bottom, 8)
            barRow("Model memory", hw.engineFootprint.map { f in budget.map { "\(Fmt.gb(f)) / \(Fmt.gb($0)) GB" } ?? "\(Fmt.gb(f)) GB" } ?? "–",
                   (hw.engineFootprint ?? 0) / (budget ?? hw.memTotal ?? 1), .accent)
            let memPct = (hw.memUsed ?? 0) / (hw.memTotal ?? 1)
            barRow("Memory", hw.memUsed.map { "\(Fmt.gb($0)) / \(Fmt.gb(hw.memTotal, 0)) GB" } ?? "–", memPct, memPct > 0.92 ? .danger : .accent)
            barRow("Swap", (hw.swapTotal ?? 0) > 0 ? "\(Fmt.gb(hw.swapUsed)) / \(Fmt.gb(hw.swapTotal)) GB" : "none",
                   (hw.swapUsed ?? 0) / max(1, hw.swapTotal ?? 1), .warn)
        }
    }

    func barRow(_ label: String, _ value: String, _ frac: Double, _ tone: Tone) -> some View {
        VStack(spacing: 8) {
            HStack {
                Text(label).outfit(13, .medium).foregroundStyle(pal.ink)
                Spacer()
                Text(value).outfit(13, .medium).foregroundStyle(pal.inkMuted)
            }
            BarView(fraction: frac, tone: tone)
        }
        .padding(.vertical, 6)
    }
}

// MARK: - recent requests

private struct RequestsCard: View {
    @EnvironmentObject var model: AppModel
    @Environment(\.pal) var pal
    static let heads = ["Time", "Client", "Status", "Prompt", "Cached", "Output", "Tok/s", "Drafts", "Duration"]

    var body: some View {
        let reqs = model.metrics["requests"].array
        let kept = model.metrics["requests_kept"].int ?? reqs.count
        let shown = model.showAllRequests ? reqs : Array(reqs.prefix(12))
        Card {
            HStack {
                CardTitle(text: "Recent requests")
                Spacer()
                if kept > 12 {
                    Button(model.showAllRequests ? "Show fewer" : "Show all (\(Fmt.n(kept)))") { model.showAllRequests.toggle() }
                        .buttonStyle(SecondaryButtonStyle(height: 32))
                }
            }
            ScrollView(.horizontal, showsIndicators: false) {
                Grid(alignment: .leading, horizontalSpacing: 0, verticalSpacing: 0) {
                    GridRow {
                        ForEach(0..<Self.heads.count, id: \.self) { c in
                            Text(Self.heads[c].uppercased()).outfit(11, .medium).foregroundStyle(pal.inkMuted)
                                .padding(.horizontal, 10).padding(.vertical, 10)
                                .gridColumnAlignment(c >= 3 ? .trailing : .leading)
                        }
                    }
                    Rectangle().fill(pal.line).frame(height: 1).gridCellUnsizedAxes(.horizontal)
                    if shown.isEmpty {
                        GridRow {
                            Text("No requests yet").outfit(14).foregroundStyle(pal.inkMuted).padding(12).gridCellColumns(Self.heads.count)
                        }
                    }
                    ForEach(Array(shown.enumerated()), id: \.offset) { _, r in
                        GridRow {
                            cell(Fmt.time(r["time"].double))
                            cell(r["client"].str)
                            status(r).padding(.horizontal, 10).padding(.vertical, 9)
                            num(Fmt.n(r["prompt_tokens"].double))
                            num(Fmt.n(r["cached_tokens"].double))
                            num(Fmt.n(r["output_tokens"].double))
                            num(Fmt.n(r["decode_tok_s"].double, 1))
                            num(drafts(r))
                            num(Fmt.n(r["duration_s"].double, 1) + " s")
                        }
                        Rectangle().fill(pal.lineSoft).frame(height: 1).gridCellUnsizedAxes(.horizontal)
                    }
                }
                .frame(minWidth: 640)
            }
            .padding(.top, 12)
            let t = totalsText(model.metrics["totals"])
            if !t.isEmpty { Muted(text: t, size: 13).padding(.top, 12) }
        }
    }

    func cell(_ s: String) -> some View {
        Text(s).outfit(13).foregroundStyle(pal.inkSoft).lineLimit(1).padding(.horizontal, 10).padding(.vertical, 9)
    }
    func num(_ s: String) -> some View {
        Text(s).outfit(13).foregroundStyle(pal.inkSoft).monospacedDigit().lineLimit(1).padding(.horizontal, 10).padding(.vertical, 9)
    }
    func drafts(_ r: J) -> String {
        guard let d = r["drafted"].double, d > 0 else { return "–" }
        return "\(Fmt.n(100 * (r["accepted"].double ?? 0) / d))%"
    }
    func status(_ r: J) -> some View {
        let f = r["finish"].str
        let text = f == "stop" || f == "end_turn" || f == "completed" ? "Done" : f == "length" || f == "max_tokens" ? "Max tokens"
            : f == "tool_calls" || f == "tool_use" ? "Tool call" : f == "cancel" ? "Stopped" : f == "error" ? "Error" : (f.isEmpty ? "–" : f)
        let tone: Tone = f == "cancel" ? .warn : f == "error" ? .danger : f == "tool_calls" || f == "tool_use" ? .info : .muted
        return Badge(text: text, tone: tone).help(r["error"].string ?? r["path"].str)
    }

    func totalsText(_ t: J) -> String {
        guard let n = t["requests"].double, n > 0 else { return "" }
        let since = Date(timeIntervalSince1970: t["since"].double ?? 0)
        let f = DateFormatter(); f.dateFormat = "EEE HH:mm"
        let prompt = t["prompt_tokens"].double ?? 0, cached = t["cached_tokens"].double ?? 0, out = t["output_tokens"].double ?? 0
        let read = max(0, prompt - cached)
        let pS = t["prefill_s"].double ?? 0, dS = t["decode_s"].double ?? 0
        return "Since \(f.string(from: since)): \(Fmt.n(n)) request\(n == 1 ? "" : "s") · \(Fmt.n(read)) prompt tokens read"
            + (pS > 0 && read > 0 ? " at \(Fmt.n(read / pS)) tok/s" : "") + " (\(Fmt.n(cached)) from the cache) · \(Fmt.n(out)) written"
            + (dS > 0 && out > 0 ? " at \(Fmt.n(out / dS, 1)) tok/s" : "")
    }
}

// MARK: - prompt cache

private struct CacheCard: View {
    @EnvironmentObject var model: AppModel
    @Environment(\.pal) var pal

    var body: some View {
        let facts = model.metrics["engine"]["facts"]
        let t = model.metrics["totals"], last = model.metrics["requests"][0]
        let prompt = t["prompt_tokens"].double ?? 0, cached = t["cached_tokens"].double ?? 0
        var rows: [(String, String)] = []
        if let p = last["prompt_tokens"].double {
            rows.append(("Last request", "\(Fmt.n(last["cached_tokens"].double ?? 0)) of \(Fmt.n(p)) prompt tokens came from the cache"))
        }
        if prompt > 0 { rows.append(("Reused since start", "\(Fmt.n(cached)) tokens (\(Fmt.n(100 * cached / prompt))% of all prompt tokens)")) }
        if let n = facts["snapshots"].int {
            rows.append(("Saved prompt snapshots", "\(n) restored when the engine started, the largest \(Fmt.n(facts["snapshot_tokens"].double)) tokens"))
        }
        if let g = facts["prompt_cache_gib"].double { rows.append(("Prompt cache", "up to \(Fmt.n(g, 1)) GiB")) }
        return TitledCard(title: "Prompt cache", trailing: prompt > 0 ? "\(Fmt.n(100 * cached / prompt))% of prompt tokens reused" : "") {
            if !rows.isEmpty { Facts(rows: rows, labelWidth: 220).padding(.top, 12) }
            Muted(text: "A request that starts like an earlier one (the same system prompt and chat so far) reuses that work instead of reading it again, so follow-ups and agents like Hermes answer sooner. TensorFold also saves long system prompts as snapshots and restores them when it starts.")
                .padding(.top, 12)
        }
    }
}

// MARK: - performance by TensorFold version

private struct PerfCard: View {
    @EnvironmentObject var model: AppModel
    @Environment(\.pal) var pal

    var body: some View {
        let rows = model.perf["rows"].array
        let current = model.perf["current_version"].str
        TitledCard(title: "Performance by TensorFold version", trailing: rows.isEmpty ? "" : "\(rows.count) configuration\(rows.count == 1 ? "" : "s")") {
            Grid(alignment: .leading, horizontalSpacing: 16, verticalSpacing: 8) {
                GridRow {
                    ForEach(["TensorFold version", "Model", "Requests", "Prefill tok/s", "Decode tok/s"], id: \.self) { h in
                        Text(h).outfit(12, .medium).foregroundStyle(pal.inkMuted)
                    }
                }
                Rectangle().fill(pal.line).frame(height: 1).gridCellUnsizedAxes(.horizontal)
                ForEach(Array(rows.enumerated()), id: \.offset) { _, r in
                    GridRow {
                        HStack(spacing: 6) {
                            Text(r["version"].str.isEmpty ? "unknown" : r["version"].str).outfit(13, .medium).foregroundStyle(pal.ink)
                            if r["version"].str == current && !current.isEmpty { Badge(text: "running", tone: .accent) }
                        }
                        Text(r["model_label"].str).outfit(12).foregroundStyle(pal.inkMuted)
                        Text(Fmt.n(r["requests"].double)).outfit(12, .medium).foregroundStyle(pal.inkMuted).gridColumnAlignment(.trailing)
                        Text(Fmt.n(r["prefill_tok_s"].double)).outfit(13, .medium).foregroundStyle(pal.ink).gridColumnAlignment(.trailing)
                        Text(Fmt.n(r["decode_tok_s"].double, 1)).outfit(13, .medium).foregroundStyle(pal.ink).gridColumnAlignment(.trailing)
                    }
                }
            }
            .padding(.top, 12)
            Muted(text: note(rows, current)).padding(.top, 12)
        }
    }

    func note(_ rows: [J], _ current: String) -> String {
        if rows.isEmpty {
            return "Nothing recorded yet. It fills as you use the model: every finished request is kept in ~/Library/Application Support/TensorFoldLauncher/state/perf/requests.jsonl, counted under the TensorFold version that served it."
        }
        var s = "Prefill is prompt tokens over the engine's own read time and decode is generated tokens over its own generation time, so a long answer counts more than a short one. Averages cover every request that version served, newest first."
        let model = rows.first { $0["version"].str == current }?["model"].str
        if let cur = rows.first(where: { $0["version"].str == current && $0["model"].str == model }),
           let prev = rows.first(where: { $0["version"].str != current && $0["model"].str == model }),
           let cp = cur["prefill_tok_s"].double, let cd = cur["decode_tok_s"].double,
           let pp = prev["prefill_tok_s"].double, let pd = prev["decode_tok_s"].double, pp > 0, pd > 0 {
            s += " On \(cur["model_label"].str), \(prev["version"].str) averaged \(Fmt.n(pp)) prefill / \(Fmt.n(pd, 1)) decode, so \(current) is "
                + "\(signed(100 * (cp - pp) / pp))% prefill and \(signed(100 * (cd - pd) / pd))% decode against it."
        }
        return s
    }

    func signed(_ v: Double) -> String { (v >= 0 ? "+" : "") + Fmt.n(v) }
}
