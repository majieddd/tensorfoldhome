import AppKit
import SwiftUI

/// What was asked on the command line (the same flags StrataHome has, where they make sense on a Mac).
struct Options {
    var minimized = false, noStart = false, drawer = false, selftest = false, probe = false
    var updateCheck = false, updateDownload = false
    var updateTest: [String]?            // URL SHA256 VERSION
    var tab: Tab?
    var theme: String?
    var size: CGSize?
    var screenshot: String?
    var delay = 3.0
    var prompt: String?
    var scroll: CGFloat = 0

    static func parse(_ args: [String]) -> Options {
        var o = Options()
        var i = 1
        func next() -> String? { i += 1; return i < args.count ? args[i] : nil }
        while i < args.count {
            switch args[i] {
            case "--minimized": o.minimized = true
            case "--no-start": o.noStart = true
            case "--drawer": o.drawer = true
            case "--selftest": o.selftest = true
            case "--probe": o.probe = true
            case "--update-check": o.updateCheck = true
            case "--update-download": o.updateCheck = true; o.updateDownload = true
            case "--update-test":
                if let u = next(), let s = next(), let v = next() { o.updateTest = [u, s, v]; o.minimized = true; o.noStart = true }
            case "--tab": o.tab = next().flatMap { Tab(rawValue: $0) }
            case "--theme": o.theme = next()
            case "--size":
                if let s = next()?.split(separator: "x"), s.count == 2, let w = Double(s[0]), let h = Double(s[1]) { o.size = CGSize(width: w, height: h) }
            case "--screenshot": o.screenshot = next()
            case "--delay": o.delay = next().flatMap(Double.init) ?? 3
            case "--prompt": o.prompt = next()
            case "--scroll": o.scroll = next().flatMap(Double.init).map { CGFloat($0) } ?? 0
            default: break
            }
            i += 1
        }
        return o
    }
}

@main
enum Main {
    static var delegate: AppDelegate?

    static func main() {
        let opts = Options.parse(CommandLine.arguments)
        if opts.selftest {
            Fonts.register()
            exit(MainActor.assumeIsolated { SelfTest.run() })
        }
        if opts.updateCheck {
            exit(MainActor.assumeIsolated { SelfTest.updateCheck(download: opts.updateDownload) })
        }
        let app = NSApplication.shared
        let d = MainActor.assumeIsolated { AppDelegate(opts) }
        delegate = d
        app.delegate = d
        app.run()
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, NSWindowDelegate, NSMenuDelegate {
    let opts: Options
    let model = AppModel()
    lazy var chat = ChatModel(model: model)
    let setup = BackendSetup()
    var window: NSWindow?
    var statusItem: NSStatusItem?
    var toldAboutMenuBar = false
    var quitting = false

    init(_ opts: Options) { self.opts = opts }

    func applicationDidFinishLaunching(_ n: Notification) {
        Fonts.register()
        Paths.ensure()
        Paths.diag("TensorFold Home \(AppModel.version) started" + (CommandLine.arguments.count > 1 ? " with \(CommandLine.arguments.dropFirst().joined(separator: " "))" : ""))
        if opts.screenshot != nil || opts.probe || opts.updateTest != nil { model.persist = false }
        if let t = opts.theme { model.settings.theme = t }
        if let t = opts.tab { model.tab = t }
        model.applyAppearance()
        if BackendSetup.syncBundled() {
            Task { _ = await Shell.tfctl("gateway", "restart") }   // the endpoint runs the new code from now
        }
        setup.refresh()
        model.showWindow = { [weak self] in self?.showWindow() }
        model.onChange = { [weak self] in self?.updateStatusItem() }
        buildMainMenu()
        buildStatusItem()
        if opts.minimized {
            NSApp.setActivationPolicy(.accessory)
            model.windowVisible = false
        } else {
            NSApp.setActivationPolicy(.regular)
            showWindow()
        }
        model.startPolling()
        Task { await model.autoStartIfWanted(noStart: opts.noStart || opts.screenshot != nil || opts.probe) }
        if opts.screenshot != nil { scheduleScreenshot() }
        if opts.probe { scheduleProbe() }
        if let t = opts.updateTest { runUpdateTest(url: t[0], sha: t[1], version: t[2]) }
    }

    // MARK: window

    func makeWindow() -> NSWindow {
        let size = opts.size ?? CGSize(width: 1240, height: 820)
        let w = NSWindow(contentRect: NSRect(origin: .zero, size: size),
                         styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
                         backing: .buffered, defer: false)
        w.title = "TensorFold Home"
        w.titlebarAppearsTransparent = true
        w.titleVisibility = .hidden
        w.isReleasedWhenClosed = false
        w.minSize = NSSize(width: 760, height: 560)
        w.delegate = self
        let root = MainView()
            .environmentObject(model)
            .environmentObject(chat)
            .environmentObject(setup)
        w.contentView = NSHostingView(rootView: root)
        if opts.size == nil { w.setFrameAutosaveName("TensorFoldHomeMain") }
        if opts.size != nil || !w.setFrameUsingName("TensorFoldHomeMain") { w.center() }
        return w
    }

    func showWindow() {
        if window == nil { window = makeWindow() }
        NSApp.setActivationPolicy(.regular)
        window?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        model.windowVisible = true
        Task { await model.refresh() }
    }

    func windowShouldClose(_ sender: NSWindow) -> Bool {
        sender.orderOut(nil)
        model.windowVisible = false
        NSApp.setActivationPolicy(.accessory)
        if !toldAboutMenuBar {
            toldAboutMenuBar = true
            NSUserNotificationLike.post(title: "TensorFold Home is still running", text: "It lives in the menu bar (the bolt). Quit it from there.")
        }
        return false
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        showWindow()
        return true
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        if model.updater.busy {
            showWindow()
            model.toast(.warn, "TensorFold Home is downloading an update", "Wait for the download to finish before quitting.", seconds: 5)
            return .terminateCancel
        }
        if quitting { return .terminateNow }
        quitting = true
        chat.stop()
        chat.save()
        model.updater.swapOnQuit()
        let commands = model.persist ? model.quitCommands() : []
        guard !commands.isEmpty else {
            Paths.diag("TensorFold Home quit")
            return .terminateNow
        }
        // terminate can be called from inside a main-queue block, so the reply must not depend on the main queue:
        // unload on a background thread, then answer through the run loop (which AppKit spins while it waits).
        let tfctl = Paths.tfctl
        DispatchQueue.global(qos: .userInitiated).async {
            for args in commands { Shell.runSync("/bin/bash", [tfctl] + args, timeout: 30) }
            Paths.diag("TensorFold Home quit (\(commands.map { $0.joined(separator: " ") }.joined(separator: ", ")))")
            RunLoop.main.perform(inModes: [.default, .modalPanel, .eventTracking]) {
                NSApp.reply(toApplicationShouldTerminate: true)
            }
            CFRunLoopWakeUp(CFRunLoopGetMain())
        }
        return .terminateLater
    }

    // MARK: menus

    func buildMainMenu() {
        let main = NSMenu()
        func item(_ title: String, _ action: Selector?, _ key: String = "", _ mods: NSEvent.ModifierFlags = .command, target: AnyObject? = nil) -> NSMenuItem {
            let i = NSMenuItem(title: title, action: action, keyEquivalent: key)
            i.keyEquivalentModifierMask = mods
            i.target = target
            return i
        }
        let appMenu = NSMenu()
        appMenu.addItem(item("About TensorFold Home", #selector(showAbout), target: self))
        appMenu.addItem(item("Check for Updates…", #selector(checkUpdates), target: self))
        appMenu.addItem(.separator())
        appMenu.addItem(item("Settings…", #selector(showServer), ",", target: self))
        appMenu.addItem(.separator())
        appMenu.addItem(item("Hide TensorFold Home", #selector(NSApplication.hide(_:)), "h"))
        appMenu.addItem(item("Hide Others", #selector(NSApplication.hideOtherApplications(_:)), "h", [.command, .option]))
        appMenu.addItem(item("Show All", #selector(NSApplication.unhideAllApplications(_:))))
        appMenu.addItem(.separator())
        appMenu.addItem(item("Quit TensorFold Home", #selector(NSApplication.terminate(_:)), "q"))
        main.addItem(withTitle: "TensorFold Home", action: nil, keyEquivalent: "").submenu = appMenu

        let file = NSMenu(title: "File")
        file.addItem(item("New Chat", #selector(newChat), "n", target: self))
        file.addItem(item("Attach File…", #selector(attach), "o", target: self))
        file.addItem(item("Save Chat as Markdown…", #selector(saveChat), "s", target: self))
        file.addItem(.separator())
        file.addItem(item("Close Window", #selector(NSWindow.performClose(_:)), "w"))
        main.addItem(withTitle: "File", action: nil, keyEquivalent: "").submenu = file

        let edit = NSMenu(title: "Edit")
        edit.addItem(item("Undo", Selector(("undo:")), "z"))
        edit.addItem(item("Redo", Selector(("redo:")), "z", [.command, .shift]))
        edit.addItem(.separator())
        edit.addItem(item("Cut", #selector(NSText.cut(_:)), "x"))
        edit.addItem(item("Copy", #selector(NSText.copy(_:)), "c"))
        edit.addItem(item("Paste", #selector(NSText.paste(_:)), "v"))
        edit.addItem(item("Select All", #selector(NSText.selectAll(_:)), "a"))
        main.addItem(withTitle: "Edit", action: nil, keyEquivalent: "").submenu = edit

        let view = NSMenu(title: "View")
        for (i, t) in Tab.allCases.enumerated() {
            let it = item(t.title, #selector(showTab(_:)), "\(i + 1)", target: self)
            it.tag = i
            view.addItem(it)
        }
        view.addItem(.separator())
        view.addItem(item("Sampling", #selector(openSampling), "e", target: self))
        main.addItem(withTitle: "View", action: nil, keyEquivalent: "").submenu = view

        let win = NSMenu(title: "Window")
        win.addItem(item("Minimize", #selector(NSWindow.performMiniaturize(_:)), "m"))
        win.addItem(item("Zoom", #selector(NSWindow.performZoom(_:))))
        main.addItem(withTitle: "Window", action: nil, keyEquivalent: "").submenu = win
        NSApp.windowsMenu = win
        NSApp.mainMenu = main
    }

    @objc func showAbout() { model.tab = .about; showWindow() }
    @objc func showServer() { model.tab = .server; showWindow() }
    @objc func checkUpdates() { model.tab = .server; showWindow(); model.updater.checkNow() }
    @objc func newChat() { model.tab = .chat; showWindow(); chat.newChat() }
    @objc func attach() { model.tab = .chat; showWindow(); chat.pickFiles() }
    @objc func saveChat() { chat.saveChat() }
    @objc func openSampling() { model.tab = .chat; showWindow(); model.drawerOpen = true }
    @objc func showTab(_ sender: NSMenuItem) { model.tab = Tab.allCases[sender.tag]; showWindow() }

    // MARK: the menu bar item (StrataHome's tray icon)

    func buildStatusItem() {
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        let menu = NSMenu()
        menu.delegate = self
        item.menu = menu
        statusItem = item
        updateStatusItem()
    }

    func updateStatusItem() {
        guard let button = statusItem?.button else { return }
        let s = model.runState
        let symbol: String
        switch s {
        case .ready: symbol = model.metrics["live"]["state"].str == "generating" ? "bolt.horizontal.fill" : "bolt.fill"
        case .unloaded: symbol = "bolt"
        case .loading, .starting, .stopping: symbol = "bolt.badge.clock"
        case .error: symbol = "exclamationmark.triangle"
        case .stopped: symbol = "bolt.slash"
        }
        if button.image?.accessibilityDescription != symbol {
            let img = NSImage(systemSymbolName: symbol, accessibilityDescription: symbol)
                ?? NSImage(systemSymbolName: "bolt", accessibilityDescription: "bolt")
            img?.isTemplate = true
            button.image = img
        }
        button.toolTip = "TensorFold: \(model.pill.text)"
    }

    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        let s = model.runState
        func add(_ title: String, _ action: Selector?, enabled: Bool = true, key: String = "") -> NSMenuItem {
            let i = NSMenuItem(title: title, action: enabled ? action : nil, keyEquivalent: key)
            i.target = self
            menu.addItem(i)
            return i
        }
        let head = NSMenuItem(title: "\(model.pill.text) · \(model.modelLabel)", action: nil, keyEquivalent: "")
        head.isEnabled = false
        menu.addItem(head)
        let show = add("Show TensorFold Home", #selector(menuShow))
        show.attributedTitle = NSAttributedString(string: show.title, attributes: [.font: NSFont.boldSystemFont(ofSize: 13)])
        menu.addItem(.separator())
        _ = add("Start", #selector(menuStart), enabled: s == .stopped)
        _ = add("Stop", #selector(menuStop), enabled: s != .stopped && s != .stopping)
        _ = add("Restart", #selector(menuRestart), enabled: s != .stopped && s != .stopping && s != .starting)
        _ = add(model.engineLoaded || s == .loading ? "Free memory now" : "Load the model now", #selector(menuMemory), enabled: s != .stopped && s != .starting)
        let models = NSMenuItem(title: "Model", action: nil, keyEquivalent: "")
        let sub = NSMenu()
        for (i, m) in model.models.enumerated() {
            let it = NSMenuItem(title: m.label, action: #selector(menuModel(_:)), keyEquivalent: "")
            it.target = self
            it.tag = i
            it.state = m.key == model.currentModelKey ? .on : .off
            sub.addItem(it)
        }
        models.submenu = sub
        menu.addItem(models)
        menu.addItem(.separator())
        _ = add("Chat", #selector(menuChat))
        _ = add("Monitor", #selector(menuMonitor))
        _ = add("Open WebUI in the browser", #selector(menuWebUI))
        _ = add("Copy API URL", #selector(menuCopy))
        menu.addItem(.separator())
        _ = add("Open log folder", #selector(menuLogs))
        let quit = add("Quit TensorFold Home", #selector(NSApplication.terminate(_:)), key: "q")
        quit.target = NSApp
    }

    @objc func menuShow() { showWindow() }
    @objc func menuStart() { model.start() }
    @objc func menuStop() { model.stop() }
    @objc func menuRestart() { model.restart() }
    @objc func menuMemory() { model.toggleMemory() }
    @objc func menuModel(_ sender: NSMenuItem) { if sender.tag < model.models.count { model.useModel(model.models[sender.tag]) } }
    @objc func menuChat() { model.tab = .chat; showWindow() }
    @objc func menuMonitor() { model.tab = .monitor; showWindow() }
    @objc func menuWebUI() { model.openWebUI() }
    @objc func menuCopy() { model.copyURL() }
    @objc func menuLogs() { NSWorkspace.shared.open(Paths.backendLogs) }

    // MARK: --probe: what this app found, written to logs/probe.txt (and whether the header gets its clicks)

    func scheduleProbe() {
        Task {
            for _ in 0..<40 where !model.polled { try? await Task.sleep(nanoseconds: 250_000_000) }
            try? await Task.sleep(nanoseconds: 1_000_000_000)
            var out = ["TensorFold Home \(AppModel.version) probe, \(ISO8601DateFormatter().string(from: Date()))"]
            out.append("backend: \(Paths.backend.path) installed=\(model.backendInstalled)")
            for c in setup.checks { out.append("  \(c.ok ? "ok " : "-- ") \(c.name): \(c.detail)") }
            out.append("endpoint: \(model.apiURL) up=\(model.gatewayUp) state=\(model.runState.title) model=\(model.currentModelKey)")
            out.append("engine: \(model.status["engine_version"].str) facts=\(model.status["engine_facts"].dict.keys.sorted().joined(separator: ","))")
            out.append("pill: \(model.pill.text)")
            if let w = window, let frame = w.contentView?.superview {
                // AppKit delivers a click to whatever the window's frame view hit-tests; it must be our content
                let h = w.contentView!.bounds.height
                for (name, x) in [("brand", 150.0), ("Chat tab", 300.0), ("Server tab", 600.0), ("theme button", w.contentView!.bounds.width - 40)] {
                    for y in [16.0, 30.0, 44.0] {
                        let p = frame.convert(NSPoint(x: x, y: h - y), from: w.contentView)
                        let hit = frame.hitTest(p)
                        let ours = hit.map { $0.isDescendant(of: w.contentView!) } ?? false
                        out.append("hit \(name) at y=\(Int(y)): " + (ours ? "content" : "TITLE BAR (\(hit.map { String(describing: type(of: $0)) } ?? "nothing"))"))
                    }
                }
            }
            let text = out.joined(separator: "\n") + "\n"
            print(text, terminator: "")
            try? text.write(to: Paths.logs.appendingPathComponent("probe.txt"), atomically: true, encoding: .utf8)
            NSApp.terminate(nil)
        }
    }

    // MARK: --update-test URL SHA VERSION: update this copy from a local server, swap on quit, don't reopen

    func runUpdateTest(url: String, sha: String, version: String) {
        let up = model.updater
        up.checkOverride = { ReleaseInfo(tag: version, url: url, sha256: sha) }
        up.reopenAfterSwap = false
        Task {
            up.checkNow()
            while up.checking { try? await Task.sleep(nanoseconds: 100_000_000) }
            Paths.diag("[update-test] available=\(up.available) latest=\(up.latest)")
            up.updateNow()
            try? await Task.sleep(nanoseconds: 200_000_000)
            while up.busy { try? await Task.sleep(nanoseconds: 100_000_000) }
            Paths.diag("[update-test] staged=\(up.staged): \(up.status)")
            NSApp.terminate(nil)
        }
    }

    // MARK: --screenshot (the README images are made with it)

    func scheduleScreenshot() {
        Task {
            // wait for the first poll, then the delay (and an answer, with --prompt)
            for _ in 0..<40 where !model.polled { try? await Task.sleep(nanoseconds: 250_000_000) }
            try? await Task.sleep(nanoseconds: UInt64(max(0.5, opts.delay) * 1e9))
            if opts.drawer { model.drawerOpen = true }
            if let p = opts.prompt, model.tab == .chat {
                chat.demo(p) { [weak self] in self?.capture() }
            } else {
                capture()
            }
        }
    }

    func capture() {
        guard let path = opts.screenshot, let view = window?.contentView else { NSApp.terminate(nil); return }
        if opts.scroll > 0, let sv = findScrollView(view) {
            sv.contentView.scroll(to: NSPoint(x: 0, y: opts.scroll))
            sv.reflectScrolledClipView(sv.contentView)
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) {
            guard let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { NSApp.terminate(nil); return }
            view.cacheDisplay(in: view.bounds, to: rep)
            if let data = rep.representation(using: .png, properties: [:]) {
                try? data.write(to: URL(fileURLWithPath: path))
                Paths.diag("screenshot written to \(path)")
            }
            NSApp.terminate(nil)
        }
    }

    private func findScrollView(_ v: NSView) -> NSScrollView? {
        if let s = v as? NSScrollView, s.documentView?.frame.height ?? 0 > s.frame.height + 50 { return s }
        for c in v.subviews { if let s = findScrollView(c) { return s } }
        return nil
    }
}

/// A banner through osascript (UNUserNotificationCenter needs a signed, notarised app to ask for permission).
enum NSUserNotificationLike {
    static func post(title: String, text: String) {
        let esc = { (s: String) in s.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"") }
        Task.detached {
            _ = await Shell.run("/usr/bin/osascript", ["-e", "display notification \"\(esc(text))\" with title \"\(esc(title))\""], timeout: 10)
        }
    }
}
