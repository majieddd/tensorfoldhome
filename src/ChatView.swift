import AppKit
import SwiftUI
import UniformTypeIdentifiers

struct Attachment: Codable, Equatable, Identifiable {
    var id = UUID()
    var name: String
    var text: String
}

struct ChatMsg: Codable, Identifiable, Equatable {
    var id = UUID()
    var role = "user"
    var text = ""
    var reasoning = ""
    var meta = ""
    var error = ""
    var stopped = false
    var thinkSecs: Double?
    var time = Date()
    var files: [Attachment] = []
}

/// The conversation, its persistence (chat.json) and the streaming request to the endpoint.
@MainActor
final class ChatModel: ObservableObject {
    @Published var messages: [ChatMsg] = []
    @Published var attachments: [Attachment] = []
    @Published var input = ""
    @Published var activeID: UUID?
    @Published var liveMeta = ""
    @Published var thinkOpen: [UUID: Bool] = [:]
    @Published var scrollTick = 0
    @Published var focusTick = 0
    var thinkTouched: Set<UUID> = []
    private var task: Task<Void, Never>?
    private var undoBackup: [ChatMsg]?
    private unowned let model: AppModel
    var demoDone: (() -> Void)?

    static var url: URL { Paths.app.appendingPathComponent("chat.json") }

    init(model: AppModel) {
        self.model = model
        if let data = try? Data(contentsOf: Self.url) {
            let dec = JSONDecoder()
            dec.dateDecodingStrategy = .iso8601
            messages = (try? dec.decode([ChatMsg].self, from: data)) ?? []
        }
    }

    var busy: Bool { activeID != nil }

    func save() {
        guard model.persist else { return }
        Paths.ensure()
        let enc = JSONEncoder()
        enc.dateEncodingStrategy = .iso8601
        if let data = try? enc.encode(messages) { try? data.write(to: Self.url, options: .atomic) }
    }

    // MARK: send

    /// The OpenAI messages: each attached file's text is fenced with more backticks than it contains itself.
    func apiMessages() -> [[String: Any]] {
        messages.compactMap { m in
            if m.role == "user" {
                var s = m.text
                for f in m.files {
                    let longest = f.text.components(separatedBy: CharacterSet(charactersIn: "`").inverted)
                        .map(\.count).max() ?? 0
                    let fence = String(repeating: "`", count: max(3, longest + 1))
                    if !s.isEmpty { s += "\n\n" }
                    s += "File: \(f.name)\n\(fence)\n\(f.text)\n\(fence)"
                }
                return ["role": "user", "content": s]
            }
            return m.error.isEmpty && !m.text.isEmpty ? ["role": "assistant", "content": m.text] : nil
        }
    }

    func send(effortOverride: String? = nil) {
        guard !busy else { return }
        let text = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty || !attachments.isEmpty else { return }
        let state = model.runState
        guard state.canChat else {
            model.toast(.warn, state == .starting ? "TensorFold is starting" : "TensorFold is not running",
                        state == .starting ? "Your message is kept: send it in a moment." : "Start it on the Server tab first.", seconds: 4.5)
            return
        }
        messages.append(ChatMsg(role: "user", text: text, files: attachments))
        attachments = []
        input = ""
        let api = apiMessages()
        let reply = ChatMsg(role: "assistant")
        messages.append(reply)
        activeID = reply.id
        liveMeta = ""
        scrollTick += 1
        model.chatStreaming = true

        let s = model.settings
        var body: [String: Any] = ["model": model.servedName, "messages": api, "stream": true,
                                   "stream_options": ["include_usage": true],
                                   "reasoning_effort": effortOverride ?? s.effort]
        if s.temperature > 0 {
            body["temperature"] = s.temperature; body["top_p"] = s.topP; body["top_k"] = s.topK
        } else {
            body["temperature"] = 0
        }
        if let n = Int(s.seed.trimmingCharacters(in: .whitespaces)) { body["seed"] = n }
        if let n = Int(s.maxTokens.trimmingCharacters(in: .whitespaces)), n > 0 { body["max_tokens"] = n }
        let url = URL(string: model.apiURL + "/chat/completions")!
        let id = reply.id
        task = Task { await self.stream(url: url, body: body, id: id) }
    }

    private func stream(url: URL, body: [String: Any], id: UUID) async {
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.timeoutInterval = 900
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.setValue(AppModel.userAgent, forHTTPHeaderField: "User-Agent")
        req.httpBody = try? JSONSerialization.data(withJSONObject: body)

        var reasoning = "", content = "", failure: String?
        var usageTokens: Int?, engineRate: Double?, drafted: Double?, accepted: Double?
        var firstAt: Date?, thinkStart: Date?, thinkSecs: Double?
        var deltas = 0
        var lastFlush = Date.distantPast

        func flush(force: Bool = false) {
            guard force || Date().timeIntervalSince(lastFlush) > 0.06 else { return }
            lastFlush = Date()
            guard let i = messages.firstIndex(where: { $0.id == id }) else { return }
            messages[i].reasoning = reasoning
            messages[i].text = content
            messages[i].thinkSecs = thinkSecs
            if let f = firstAt, deltas > 1 {
                let secs = Date().timeIntervalSince(f)
                liveMeta = "\(Fmt.n(Double(deltas))) tokens" + (secs > 0.3 ? " · \(Fmt.n(Double(deltas - 1) / secs, 1)) tok/s" : "")
            }
            if model.settings.showThinking, content.isEmpty, !reasoning.isEmpty, !thinkTouched.contains(id), thinkOpen[id] == nil {
                thinkOpen[id] = true
            }
            if !content.isEmpty, thinkOpen[id] == true, !thinkTouched.contains(id) { thinkOpen[id] = false }
            scrollTick += 1
        }

        do {
            let (bytes, resp) = try await HTTP.session.bytes(for: req)
            let code = (resp as? HTTPURLResponse)?.statusCode ?? 0
            if code != 200 {
                var raw = ""
                for try await line in bytes.lines { raw += line; if raw.count > 4000 { break } }
                let msg = J.parse(raw.data(using: .utf8))["error"]["message"].string
                failure = msg ?? "HTTP \(code)"
                if code == 401 { failure = "The endpoint asked for an API key. Requests from this Mac should not need one; check Server > Network." }
            } else {
                for try await line in bytes.lines {
                    if Task.isCancelled { break }
                    guard line.hasPrefix("data:") else { continue }
                    let data = line.dropFirst(5).trimmingCharacters(in: .whitespaces)
                    if data == "[DONE]" { continue }
                    let o = J.parse(data.data(using: .utf8))
                    if !o["error"].isNull { failure = o["error"]["message"].string ?? "The engine reported an error"; break }
                    if let c = o["usage"]["completion_tokens"].int { usageTokens = c }
                    if let r = o["tensorfold"]["tokens_per_second"].double, r > 0 { engineRate = r }
                    if let d = o["speculative"]["drafted"].double { drafted = d; accepted = o["speculative"]["accepted"].double }
                    let delta = o["choices"][0]["delta"]
                    let r = delta["reasoning_content"].string ?? delta["reasoning"].string ?? ""
                    let c = delta["content"].string ?? ""
                    if !r.isEmpty {
                        reasoning += r
                        if firstAt == nil { firstAt = Date() }
                        if thinkStart == nil { thinkStart = Date() }
                        deltas += 1
                    }
                    if !c.isEmpty {
                        if firstAt == nil { firstAt = Date() }
                        if let t = thinkStart, thinkSecs == nil { thinkSecs = Date().timeIntervalSince(t) }
                        content += c
                        deltas += 1
                    }
                    flush()
                }
            }
        } catch {
            if !Task.isCancelled && (error as? URLError)?.code != .cancelled {
                let e = error as? URLError
                failure = e?.code == .cannotConnectToHost ? "The endpoint is not running. Start it on the Server tab." : error.localizedDescription
            }
        }
        let stopped = Task.isCancelled
        if let t = thinkStart, thinkSecs == nil { thinkSecs = Date().timeIntervalSince(t) }
        flush(force: true)
        guard let i = messages.firstIndex(where: { $0.id == id }) else { return }
        messages[i].error = failure ?? ""
        messages[i].stopped = stopped
        let tokens = usageTokens ?? (stopped ? deltas : nil)
        if let tokens, tokens > 0 {
            var rate = engineRate
            if rate == nil, let f = firstAt, tokens > 1 { rate = Double(tokens - 1) / max(0.001, Date().timeIntervalSince(f)) }
            var meta = "\(Fmt.n(Double(tokens))) tokens"
            if let r = rate { meta += " · \(Fmt.n(r, 1)) tok/s" }
            if let d = drafted, d > 0, let a = accepted { meta += " · \(Fmt.n(100 * a / d))% of drafts kept" }
            if stopped { meta += " · stopped" }
            messages[i].meta = meta
        } else if stopped {
            messages[i].meta = "Stopped"
        }
        if let e = failure { model.toast(.error, "The request failed", e, seconds: 6) }
        activeID = nil
        liveMeta = ""
        task = nil
        model.chatStreaming = false
        scrollTick += 1
        save()
        if let done = demoDone {
            demoDone = nil
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.7) { done() }
        }
    }

    func stop() { task?.cancel() }

    // MARK: new chat, save, attachments

    func newChat() {
        if busy { model.toast(.warn, "Still writing", "Stop the answer first.", seconds: 3.5); return }
        guard !messages.isEmpty else { return }
        undoBackup = messages
        messages = []
        thinkOpen = [:]
        save()
        model.toast(.info, "New chat", "The last one was cleared.", seconds: 6, action: "Undo") { [weak self] in
            guard let self, let b = self.undoBackup else { return }
            self.messages = b
            self.undoBackup = nil
            self.save()
            self.scrollTick += 1
        }
    }

    func markdownExport() -> String {
        var s = ""
        for m in messages {
            if m.role == "user" { s += "## You\n\n\(m.text)\n\n"; continue }
            s += "## \(model.modelLabel)\n\n"
            if !m.reasoning.isEmpty { s += "<details><summary>Thinking</summary>\n\n\(m.reasoning)\n\n</details>\n\n" }
            s += (m.text.isEmpty ? m.error : m.text) + "\n\n"
        }
        return s
    }

    func saveChat() {
        guard !messages.isEmpty else { model.toast(.info, "Nothing to save yet"); return }
        let panel = NSSavePanel()
        panel.allowedContentTypes = [UTType(filenameExtension: "md") ?? .plainText]
        let f = DateFormatter(); f.dateFormat = "yyyy-MM-dd-HH-mm"
        panel.nameFieldStringValue = "tensorfold-chat-\(f.string(from: Date())).md"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            try markdownExport().write(to: url, atomically: true, encoding: .utf8)
            model.toast(.success, "Chat saved", url.lastPathComponent)
        } catch {
            model.toast(.error, "Not saved", error.localizedDescription, seconds: 5)
        }
    }

    func pickFiles() {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = true
        panel.canChooseDirectories = false
        if panel.runModal() == .OK { addFiles(panel.urls) }
    }

    static let textExt: Set<String> = ["txt", "md", "markdown", "rst", "tex", "py", "pyi", "ipynb", "js", "mjs", "cjs", "ts", "tsx",
        "jsx", "vue", "svelte", "json", "jsonl", "csv", "tsv", "log", "yml", "yaml", "toml", "ini", "cfg", "conf", "env", "xml",
        "html", "htm", "css", "scss", "less", "c", "cc", "cpp", "cxx", "h", "hh", "hpp", "m", "mm", "cu", "cuh", "rs", "go",
        "java", "kt", "kts", "swift", "rb", "php", "pl", "lua", "r", "jl", "scala", "sql", "sh", "bash", "zsh", "fish", "ps1",
        "bat", "cmd", "diff", "patch", "gradle", "cmake", "mk", "dockerfile", "gitignore", "proto", "graphql", "cs", "zig", "plist"]

    func addFiles(_ urls: [URL]) {
        for url in urls {
            let name = url.lastPathComponent
            let ext = url.pathExtension.lowercased()
            let bare = ["makefile", "dockerfile", "readme", "license", "gemfile", "podfile"].contains(name.lowercased())
            guard Self.textExt.contains(ext) || bare else {
                model.toast(.warn, "Not a text file", "\(name): attach text files (code, notes, logs, data).", seconds: 5); continue
            }
            let size = (try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? Int) ?? 0
            guard size <= 512 * 1024 else { model.toast(.warn, "File too large", "\(name) is over 512 KB.", seconds: 5); continue }
            guard let data = try? Data(contentsOf: url), !data.contains(0), let text = String(data: data, encoding: .utf8) else {
                model.toast(.warn, "Not a text file", "\(name) looks like a binary file.", seconds: 5); continue
            }
            attachments.append(Attachment(name: name, text: text))
        }
        focusTick += 1
    }

    /// --screenshot with --prompt: send one message and call back when the answer is complete.
    func demo(_ prompt: String, done: @escaping () -> Void) {
        demoDone = done
        input = prompt
        send(effortOverride: "low")
    }
}

// MARK: - the view

struct ChatView: View {
    @EnvironmentObject var model: AppModel
    @EnvironmentObject var chat: ChatModel
    @Environment(\.pal) var pal
    @State private var atBottom = true
    @State private var viewport: CGFloat = 0
    @State private var composerHeight: CGFloat = 48
    @State private var focused = false
    @State private var dropping = false

    var body: some View {
        VStack(spacing: 0) {
            GeometryReader { outer in
                ScrollViewReader { proxy in
                    ScrollView {
                        VStack(alignment: .leading, spacing: 24) {
                            if chat.messages.isEmpty { empty }
                            ForEach(chat.messages) { m in
                                if m.role == "user" { UserBubble(m: m) } else { AssistantMessage(m: m) }
                            }
                            Color.clear.frame(height: 1).id("bottom")
                                .background(GeometryReader { g in
                                    Color.clear.preference(key: BottomKey.self, value: g.frame(in: .named("chat")).minY)
                                })
                        }
                        .frame(maxWidth: 860)
                        .padding(.horizontal, 24).padding(.top, 32).padding(.bottom, 24)
                        .frame(maxWidth: .infinity)
                    }
                    .coordinateSpace(name: "chat")
                    .onPreferenceChange(BottomKey.self) { y in atBottom = y - outer.size.height < 140 }
                    .onChange(of: chat.scrollTick) { _, _ in
                        if atBottom || chat.activeID == nil { withAnimation(.easeOut(duration: 0.12)) { proxy.scrollTo("bottom", anchor: .bottom) } }
                    }
                    .onAppear {
                        viewport = outer.size.height
                        DispatchQueue.main.async { proxy.scrollTo("bottom", anchor: .bottom) }
                    }
                }
                .onChange(of: outer.size.height) { _, v in viewport = v }
            }
            composer
        }
        .onDrop(of: [.fileURL], isTargeted: $dropping) { providers in
            for p in providers {
                _ = p.loadObject(ofClass: URL.self) { url, _ in
                    if let url { DispatchQueue.main.async { chat.addFiles([url]) } }
                }
            }
            return true
        }
        .overlay(dropping ? RoundedRectangle(cornerRadius: 20).stroke(pal.accent, style: StrokeStyle(lineWidth: 2, dash: [6, 4])).padding(12) : nil)
    }

    var empty: some View {
        VStack(spacing: 12) {
            Text("Ask anything").outfit(40, .black).foregroundStyle(pal.ink)
            Text(emptySub).outfit(16).foregroundStyle(pal.inkMuted).multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity)
        .padding(.top, 90)
    }

    var emptySub: String {
        switch model.runState {
        case .ready, .unloaded, .loading: return "\(model.modelLabel) runs on this Mac. Nothing leaves it."
        case .starting: return "TensorFold is starting. You can type while it loads."
        default: return model.polled ? "TensorFold is not running. Start it on the Server tab." : "Connecting…"
        }
    }

    var composer: some View {
        VStack(alignment: .leading, spacing: 6) {
            if !chat.attachments.isEmpty {
                HStack(spacing: 8) {
                    ForEach(chat.attachments) { a in
                        FileChip(name: a.name) { chat.attachments.removeAll { $0.id == a.id } }
                    }
                    Spacer(minLength: 0)
                }
                .padding(.horizontal, 2).padding(.top, 2)
            }
            ComposerField(text: $chat.input, height: $composerHeight, focused: $focused,
                          maxHeight: max(96, viewport * 0.4), focusTick: chat.focusTick, pal: pal,
                          placeholder: "Ask anything…", onSubmit: { chat.send() }, onFiles: { chat.addFiles($0) })
                .frame(height: composerHeight)
            HStack(spacing: 4) {
                IconButton(symbol: "paperclip", help: "Attach a text file (or drop it here)") { chat.pickFiles() }
                IconButton(symbol: "plus.bubble", help: "New chat") { chat.newChat() }
                IconButton(symbol: "square.and.arrow.down", help: "Save this chat as Markdown") { chat.saveChat() }
                IconButton(symbol: "slider.horizontal.3", help: "Sampling and thinking") { withAnimation(.easeOut(duration: 0.22)) { model.drawerOpen = true } }
                Spacer()
                if chat.busy {
                    Button { chat.stop() } label: { Label("Stop", systemImage: "stop.fill") }
                        .buttonStyle(SecondaryButtonStyle(height: 40))
                } else {
                    Text("Shift+Return: new line").outfit(12).foregroundStyle(pal.inkMuted).padding(.trailing, 8)
                }
                Button { chat.send() } label: { Image(systemName: "paperplane.fill").font(.system(size: 15, weight: .semibold)).frame(width: 42) }
                    .buttonStyle(PrimaryButtonStyle(height: 40, hPad: 0))
                    .disabled(chat.busy)
                    .help("Send (Return)")
            }
        }
        .padding(10)
        .background(RoundedRectangle(cornerRadius: 20).fill(pal.surface))
        .overlay(RoundedRectangle(cornerRadius: 20).stroke(focused ? pal.focus : pal.line, lineWidth: 1.2))
        .shadow(color: .black.opacity(pal.dark ? 0.3 : 0.09), radius: 12, y: 6)
        .frame(maxWidth: 860)
        .padding(.horizontal, 24).padding(.bottom, 24).padding(.top, 4)
        .frame(maxWidth: .infinity)
    }
}

private struct BottomKey: PreferenceKey {
    static var defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) { value = nextValue() }
}

struct FileChip: View {
    @Environment(\.pal) var pal
    let name: String
    var remove: (() -> Void)? = nil
    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: "paperclip").font(.system(size: 12)).foregroundStyle(pal.inkSoft)
            Text(name).outfit(12).foregroundStyle(pal.inkSoft).lineLimit(1)
            if let remove {
                Button(action: remove) { Image(systemName: "xmark").font(.system(size: 10, weight: .bold)).foregroundStyle(pal.inkMuted) }
                    .buttonStyle(.plain).help("Remove")
            }
        }
        .padding(.horizontal, 10).frame(height: 30)
        .background(Capsule().fill(pal.surface2))
        .overlay(Capsule().stroke(pal.line, lineWidth: 1))
    }
}

private struct UserBubble: View {
    @Environment(\.pal) var pal
    let m: ChatMsg
    var body: some View {
        VStack(alignment: .trailing, spacing: 6) {
            if !m.files.isEmpty {
                HStack(spacing: 8) { ForEach(m.files) { FileChip(name: $0.name) } }
            }
            if !m.text.isEmpty {
                Text(m.text).outfit(16).foregroundStyle(pal.accentInk)
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.horizontal, 16).padding(.vertical, 12)
                    .background(UnevenRoundedRectangle(topLeadingRadius: 20, bottomLeadingRadius: 20, bottomTrailingRadius: 6, topTrailingRadius: 20).fill(pal.accent))
            }
            Text("You · \(Fmt.plain(m.time.formatted(date: .omitted, time: .shortened)))").outfit(12).foregroundStyle(pal.inkMuted)
        }
        .frame(maxWidth: 720, alignment: .trailing)
        .frame(maxWidth: .infinity, alignment: .trailing)
    }
}

private struct AssistantMessage: View {
    @Environment(\.pal) var pal
    @EnvironmentObject var model: AppModel
    @EnvironmentObject var chat: ChatModel
    let m: ChatMsg

    var streaming: Bool { chat.activeID == m.id }
    var open: Bool { chat.thinkOpen[m.id] ?? false }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if !m.reasoning.isEmpty { thinking }
            Group {
                if !m.error.isEmpty {
                    Text(m.error).outfit(14).foregroundStyle(pal.dangerText).fixedSize(horizontal: false, vertical: true)
                        .padding(.horizontal, 14).padding(.vertical, 10)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(RoundedRectangle(cornerRadius: 14).fill(pal.dangerTint))
                } else if m.text.isEmpty {
                    Text(streaming ? (m.reasoning.isEmpty ? "…" : "Writing") : (m.stopped ? "Stopped before any answer." : "(no answer)"))
                        .outfit(16).foregroundStyle(pal.inkMuted)
                } else {
                    MarkdownView(text: m.text, size: 15.5)
                }
            }
            .padding(.horizontal, 16).padding(.vertical, 12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(UnevenRoundedRectangle(topLeadingRadius: 20, bottomLeadingRadius: 6, bottomTrailingRadius: 20, topTrailingRadius: 20).fill(pal.surface))
            .overlay(UnevenRoundedRectangle(topLeadingRadius: 20, bottomLeadingRadius: 6, bottomTrailingRadius: 20, topTrailingRadius: 20).stroke(pal.line, lineWidth: 1))
            HStack(spacing: 8) {
                let meta = !m.meta.isEmpty ? m.meta : streaming ? chat.liveMeta : (m.stopped ? "Stopped" : "")
                if !meta.isEmpty { Text(meta).outfit(12).foregroundStyle(pal.inkMuted) }
                if !streaming && !m.text.isEmpty {
                    IconButton(symbol: "doc.on.doc", help: "Copy the answer", size: 28, iconSize: 13) {
                        Clip.copy(m.text)
                        model.toast(.success, "Copied", "", seconds: 1.5)
                    }
                }
            }
            .frame(minHeight: 20)
        }
        .frame(maxWidth: 720, alignment: .leading)
    }

    var thinking: some View {
        VStack(alignment: .leading, spacing: 0) {
            Button {
                chat.thinkTouched.insert(m.id)
                chat.thinkOpen[m.id] = !open
            } label: {
                HStack(spacing: 8) {
                    Image(systemName: "lightbulb").font(.system(size: 14)).foregroundStyle(pal.inkMuted)
                    Text(streaming && m.text.isEmpty ? "Thinking…" : m.thinkSecs.map { "Thought for \(Fmt.n($0, 1)) s" } ?? "Thoughts")
                        .outfit(13, .medium).foregroundStyle(pal.inkMuted)
                    Spacer()
                    Image(systemName: "chevron.down").font(.system(size: 12, weight: .semibold)).foregroundStyle(pal.inkMuted)
                        .rotationEffect(.degrees(open ? 180 : 0))
                }
                .padding(.horizontal, 14).frame(height: 40)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            if open {
                ScrollView {
                    Text(m.reasoning).outfit(13).foregroundStyle(pal.inkMuted).lineSpacing(4)
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .frame(maxHeight: 420)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.horizontal, 14).padding(.bottom, 14)
            }
        }
        .background(RoundedRectangle(cornerRadius: 14).fill(pal.surface2))
        .overlay(RoundedRectangle(cornerRadius: 14).stroke(pal.line, lineWidth: 1))
    }
}

// MARK: - the composer's text view (Return sends, Shift+Return is a new line, files can be dropped or pasted)

struct ComposerField: NSViewRepresentable {
    @Binding var text: String
    @Binding var height: CGFloat
    @Binding var focused: Bool
    var maxHeight: CGFloat
    var focusTick: Int
    var pal: Palette
    var placeholder: String
    var onSubmit: () -> Void
    var onFiles: ([URL]) -> Void

    final class TV: NSTextView {
        var onSubmit: (() -> Void)?
        var onFocus: ((Bool) -> Void)?
        var onFiles: (([URL]) -> Void)?
        var placeholderString: NSAttributedString?

        override func keyDown(with e: NSEvent) {
            let isReturn = e.keyCode == 36 || e.keyCode == 76
            if isReturn && !e.modifierFlags.contains(.shift) && !e.modifierFlags.contains(.option) && !hasMarkedText() {
                onSubmit?()
                return
            }
            super.keyDown(with: e)
        }
        override func becomeFirstResponder() -> Bool {
            let ok = super.becomeFirstResponder()
            if ok { onFocus?(true) }
            return ok
        }
        override func resignFirstResponder() -> Bool {
            let ok = super.resignFirstResponder()
            if ok { onFocus?(false) }
            return ok
        }
        override func draw(_ rect: NSRect) {
            super.draw(rect)
            if string.isEmpty, let p = placeholderString {
                p.draw(at: NSPoint(x: textContainerInset.width + (textContainer?.lineFragmentPadding ?? 5), y: textContainerInset.height))
            }
        }
        private func fileURLs(_ pb: NSPasteboard) -> [URL] {
            (pb.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL]) ?? []
        }
        override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
            let urls = fileURLs(sender.draggingPasteboard)
            if !urls.isEmpty { onFiles?(urls); return true }
            return super.performDragOperation(sender)
        }
        override func paste(_ sender: Any?) {
            let urls = fileURLs(NSPasteboard.general)
            if !urls.isEmpty { onFiles?(urls); return }
            pasteAsPlainText(sender)
        }
    }

    final class Coordinator: NSObject, NSTextViewDelegate {
        var parent: ComposerField
        weak var tv: TV?
        var lastFocusTick = -1
        init(_ p: ComposerField) { parent = p }
        func textDidChange(_ n: Notification) {
            guard let tv else { return }
            parent.text = tv.string
            measure()
        }
        func measure() {
            guard let tv, let lm = tv.layoutManager, let tc = tv.textContainer else { return }
            lm.ensureLayout(for: tc)
            let h = ceil(lm.usedRect(for: tc).height + tv.textContainerInset.height * 2)
            let clamped = min(max(48, h), parent.maxHeight)
            if abs(clamped - parent.height) > 0.5 { DispatchQueue.main.async { self.parent.height = clamped } }
        }
    }

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeNSView(context: Context) -> NSScrollView {
        let scroll = NSScrollView()
        scroll.drawsBackground = false
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        scroll.borderType = .noBorder
        let tv = TV(frame: .zero)
        tv.isRichText = false
        tv.allowsUndo = true
        tv.drawsBackground = false
        tv.isVerticallyResizable = true
        tv.isHorizontallyResizable = false
        tv.autoresizingMask = [.width]
        tv.textContainer?.widthTracksTextView = true
        tv.textContainerInset = NSSize(width: 4, height: 8)
        tv.isAutomaticQuoteSubstitutionEnabled = false
        tv.isAutomaticDashSubstitutionEnabled = false
        tv.isAutomaticTextReplacementEnabled = false
        tv.delegate = context.coordinator
        tv.onSubmit = { onSubmit() }
        tv.onFocus = { f in DispatchQueue.main.async { focused = f } }
        tv.onFiles = { onFiles($0) }
        tv.registerForDraggedTypes([.fileURL])
        scroll.documentView = tv
        context.coordinator.tv = tv
        style(tv)
        tv.string = text
        DispatchQueue.main.async { tv.window?.makeFirstResponder(tv) }
        return scroll
    }

    func updateNSView(_ scroll: NSScrollView, context: Context) {
        context.coordinator.parent = self
        guard let tv = context.coordinator.tv else { return }
        if tv.string != text { tv.string = text; tv.needsDisplay = true }
        style(tv)
        context.coordinator.measure()
        if context.coordinator.lastFocusTick != focusTick {
            context.coordinator.lastFocusTick = focusTick
            DispatchQueue.main.async { tv.window?.makeFirstResponder(tv) }
        }
    }

    private func style(_ tv: TV) {
        let font = NSFont(name: Fonts.registered ? "Outfit-Regular" : "Helvetica", size: 16) ?? .systemFont(ofSize: 16)
        tv.font = font
        tv.textColor = NSColor(pal.ink)
        tv.insertionPointColor = NSColor(pal.ink)
        tv.typingAttributes = [.font: font, .foregroundColor: NSColor(pal.ink)]
        tv.selectedTextAttributes = [.backgroundColor: NSColor(pal.focus).withAlphaComponent(0.3)]
        tv.placeholderString = NSAttributedString(string: placeholder, attributes: [.font: font, .foregroundColor: NSColor(pal.inkMuted)])
    }
}
