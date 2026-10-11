import AppKit
import CryptoKit
import Foundation

struct ReleaseInfo {
    var tag = "", url = "", sha256 = "", notes = ""
}

/// TensorFold Home's own updates, the way StrataHome does them: check the latest GitHub release, download the
/// app's zip, verify its SHA-256 against the digest GitHub publishes for that asset, stage it, and swap it in
/// when the app quits (a recovery copy of the running version is kept in updates/app-before-<version>).
@MainActor
final class SelfUpdater: ObservableObject {
    static let repo = "majieddd/tensorfoldhome"
    static let asset = "TensorFoldHome.zip"

    @Published var checking = false
    @Published var busy = false
    @Published var available = false
    @Published var staged = false
    @Published var latest = ""
    @Published var status = "No update check yet."

    private unowned let model: AppModel
    private var nextCheck = Date().addingTimeInterval(20)
    var checkOverride: (() async -> ReleaseInfo?)?     // tests
    var reopenAfterSwap = true                         // tests swap without opening the new copy

    static var pendingFile: URL { Paths.updates.appendingPathComponent("app-pending.json") }

    init(model: AppModel) {
        self.model = model
        if let p = Self.pending(), FileManager.default.fileExists(atPath: p.app) {
            staged = true
            latest = p.version
            status = "TensorFold Home \(p.version) is downloaded and verified. It is put in when this app quits."
        }
    }

    func tick() {
        guard model.settings.autoUpdateApp, !checking, !busy, Date() >= nextCheck else { return }
        check(notify: false)
    }

    // MARK: versions

    static func normalize(_ tag: String) -> String {
        var t = tag.trimmingCharacters(in: .whitespaces)
        if t.lowercased().hasPrefix("v") { t.removeFirst() }
        return t
    }

    /// 1 when a is newer, -1 when older, 0 when equal; missing parts count as 0 (0.2 == 0.2.0).
    static func compare(_ a: String, _ b: String) -> Int {
        let x = normalize(a).split(separator: ".").map { Int($0.prefix { $0.isNumber }) ?? 0 }
        let y = normalize(b).split(separator: ".").map { Int($0.prefix { $0.isNumber }) ?? 0 }
        for i in 0..<max(x.count, y.count) {
            let p = i < x.count ? x[i] : 0, q = i < y.count ? y[i] : 0
            if p != q { return p > q ? 1 : -1 }
        }
        return 0
    }

    static func sha256(_ url: URL) -> String? {
        guard let h = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? h.close() }
        var hasher = SHA256()
        while let chunk = try? h.read(upToCount: 1 << 20), !chunk.isEmpty { hasher.update(data: chunk) }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }

    // MARK: check

    static func fetchLatest() async -> (ReleaseInfo?, String?) {
        guard let url = URL(string: "https://api.github.com/repos/\(repo)/releases/latest") else { return (nil, "bad URL") }
        var req = URLRequest(url: url)
        req.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        req.setValue(AppModel.userAgent, forHTTPHeaderField: "User-Agent")
        req.timeoutInterval = 15
        guard let (data, resp) = try? await URLSession.shared.data(for: req) else { return (nil, "no network") }
        let code = (resp as? HTTPURLResponse)?.statusCode ?? 0
        if code == 404 { return (nil, "no release published yet") }
        guard code == 200 else { return (nil, "GitHub answered HTTP \(code)") }
        let j = J.parse(data)
        var info = ReleaseInfo(tag: j["tag_name"].str, notes: j["body"].str)
        for a in j["assets"].array where a["name"].str == asset {
            info.url = a["browser_download_url"].str
            let d = a["digest"].str
            if d.hasPrefix("sha256:") { info.sha256 = String(d.dropFirst(7)).lowercased() }
        }
        return info.url.isEmpty ? (nil, "the release has no \(asset)") : (info, nil)
    }

    func checkNow() { check(notify: true) }

    private func check(notify: Bool) {
        guard !checking, !busy else { return }
        nextCheck = Date().addingTimeInterval(6 * 3600)
        checking = true
        status = "Checking TensorFold Home releases…"
        Task {
            let (info, why): (ReleaseInfo?, String?) = checkOverride != nil ? (await checkOverride!(), nil) : await Self.fetchLatest()
            checking = false
            guard let info else {
                status = "Could not check TensorFold Home releases (\(why ?? "unreachable"))."
                if notify { model.toast(.warn, "Update check failed", status, seconds: 6) }
                return
            }
            latest = Self.normalize(info.tag)
            available = Self.compare(latest, AppModel.version) > 0
            status = available
                ? "TensorFold Home \(latest) is available (you have \(AppModel.version)). Update downloads and verifies it; it is put in when this app quits."
                : "TensorFold Home is up to date. Installed: \(AppModel.version). Latest: \(latest)."
            model.log("[app-update] \(status)")
            if notify { model.toast(.success, available ? "Update available" : "Up to date", status, seconds: 6) }
        }
    }

    // MARK: download, verify, stage

    func updateNow() {
        guard !busy, !checking, !staged else { return }
        guard available else { check(notify: true); return }
        busy = true
        status = "Downloading TensorFold Home \(latest)…"
        Task {
            let info: ReleaseInfo? = checkOverride != nil ? await checkOverride!() : await Self.fetchLatest().0
            let (app, message) = await Self.download(info)
            busy = false
            guard let app else {
                status = message
                model.log("[app-update] \(message)")
                model.toast(.warn, "Update refused", message, seconds: 9)
                return
            }
            staged = true
            status = "TensorFold Home \(latest) is downloaded and verified. It is put in when this app quits; the version you have is kept as a recovery copy."
            model.log("[app-update] staged \(app)")
            model.toast(.success, "TensorFold Home \(latest) is ready", "Quit the app to install it. It reopens on the new version.", seconds: 9,
                        action: "Quit and install") { NSApp.terminate(nil) }
        }
    }

    /// Download the zip, check its SHA-256 against the release digest, unpack it and check the bundle. Returns the
    /// staged .app path, or nil with the reason.
    static func download(_ info: ReleaseInfo?, stage: Bool = true) async -> (String?, String) {
        guard let info, let url = URL(string: info.url) else { return (nil, "The release has no \(asset) to download.") }
        guard !info.sha256.isEmpty else {
            return (nil, "The release publishes no SHA-256 for \(asset), so the download cannot be verified. Nothing was staged.")
        }
        let version = normalize(info.tag)
        let dir = Paths.updates.appendingPathComponent("app-\(version)")
        let fm = FileManager.default
        try? fm.removeItem(at: dir)
        try? fm.createDirectory(at: dir, withIntermediateDirectories: true)
        let zip = dir.appendingPathComponent(asset)
        var req = URLRequest(url: url)
        req.setValue(AppModel.userAgent, forHTTPHeaderField: "User-Agent")
        guard let (tmp, resp) = try? await URLSession.shared.download(for: req), (resp as? HTTPURLResponse)?.statusCode == 200 else {
            return (nil, "The download failed.")
        }
        try? fm.removeItem(at: zip)
        do { try fm.moveItem(at: tmp, to: zip) } catch { return (nil, "The download could not be saved: \(error.localizedDescription)") }
        if let refusal = verify(zip, expected: info.sha256) {
            try? fm.removeItem(at: dir)
            return (nil, refusal)
        }
        let (code, out) = await Shell.run("/usr/bin/ditto", ["-x", "-k", zip.path, dir.path], timeout: 120)
        guard code == 0 else { return (nil, "The zip did not unpack: \(out)") }
        guard let app = (try? fm.contentsOfDirectory(atPath: dir.path))?.first(where: { $0.hasSuffix(".app") }) else {
            return (nil, "The zip holds no app. Nothing was staged.")
        }
        let appPath = dir.appendingPathComponent(app).path
        let plist = NSDictionary(contentsOfFile: appPath + "/Contents/Info.plist")
        guard plist?["CFBundleIdentifier"] as? String == AppModel.bundleID else {
            return (nil, "The downloaded app is not TensorFold Home. Nothing was staged.")
        }
        let bundleVersion = plist?["CFBundleShortVersionString"] as? String ?? ""
        guard compare(bundleVersion, version) == 0 else {
            return (nil, "The downloaded app says it is \(bundleVersion), the release says \(version). Nothing was staged.")
        }
        if !stage {
            try? fm.removeItem(at: dir)
            return (appPath, "verified: SHA-256 \(info.sha256), TensorFold Home \(bundleVersion); nothing staged")
        }
        let pending = ["app": appPath, "version": version]
        guard let data = try? JSONSerialization.data(withJSONObject: pending), (try? data.write(to: pendingFile)) != nil else {
            return (nil, "Could not record the staged update.")
        }
        return (appPath, "")
    }

    /// nil when the file matches the SHA-256 the release publishes; otherwise why it is refused.
    static func verify(_ file: URL, expected: String) -> String? {
        guard !expected.isEmpty else {
            return "The release publishes no SHA-256 for \(asset), so the download cannot be verified. Nothing was staged."
        }
        let got = sha256(file) ?? "unreadable"
        return got == expected.lowercased() ? nil : "The download's SHA-256 is \(got), the release says \(expected). Nothing was staged."
    }

    static func pending() -> (app: String, version: String)? {
        guard let data = try? Data(contentsOf: pendingFile) else { return nil }
        let j = J.parse(data)
        guard let app = j["app"].string, let v = j["version"].string else { return nil }
        return (app, v)
    }

    /// Called as the app quits: a detached helper waits for this process to exit, keeps a copy of this version,
    /// moves the staged app into place and opens it.
    func swapOnQuit() {
        guard staged, let p = Self.pending() else { return }
        let current = Bundle.main.bundlePath
        guard current.hasSuffix(".app"), FileManager.default.isWritableFile(atPath: (current as NSString).deletingLastPathComponent) else {
            model.log("[app-update] cannot swap: \(current) is not writable")
            return
        }
        let backup = Paths.updates.appendingPathComponent("app-before-\(AppModel.version)").path
        let script = """
        while kill -0 \(ProcessInfo.processInfo.processIdentifier) 2>/dev/null; do sleep 0.3; done
        [ -d \(q(p.app)) ] || exit 1
        rm -rf \(q(backup)); mkdir -p \(q(backup))
        /usr/bin/ditto \(q(current)) \(q(backup + "/" + (current as NSString).lastPathComponent)) || exit 1
        rm -rf \(q(current)) && /usr/bin/ditto \(q(p.app)) \(q(current)) || { /usr/bin/ditto \(q(backup + "/" + (current as NSString).lastPathComponent)) \(q(current)); exit 1; }
        /usr/bin/xattr -dr com.apple.quarantine \(q(current)) 2>/dev/null
        rm -f \(q(Self.pendingFile.path))
        rm -rf \(q((p.app as NSString).deletingLastPathComponent))
        \(reopenAfterSwap ? "/usr/bin/open \(q(current))" : "true")
        """
        let p2 = Process()
        p2.executableURL = URL(fileURLWithPath: "/bin/bash")
        p2.arguments = ["-c", script]
        p2.standardOutput = FileHandle.nullDevice
        p2.standardError = FileHandle.nullDevice
        try? p2.run()
        model.log("[app-update] swap to \(p.version) handed to a helper; recovery copy in \(backup)")
    }

    private func q(_ s: String) -> String { "'" + s.replacingOccurrences(of: "'", with: "'\\''") + "'" }
}

/// TensorFold's own updates (Homebrew 1.0.x, the 0.6 venv, Open WebUI), run by the backend's tf-update with its
/// health checks and rollback. The daily launchd job does the same unattended.
@MainActor
final class EngineUpdates: ObservableObject {
    @Published var running: String?    // "check" | "update"
    @Published var lastOutput = ""
    private unowned let model: AppModel

    init(model: AppModel) { self.model = model }

    var report: J {
        J.parse(try? Data(contentsOf: Paths.backend.appendingPathComponent("state/update.json")))
    }

    var summary: String {
        let r = report
        guard !r.isNull else { return "No update check yet." }
        let when = r["checked_at"].str
        let what = r["mode"].str == "--check" ? "Checked" : r["mode"].str == "--auto" ? "Daily update" : "Updated"
        return "\(what) \(when): \(r["summary"].str)."
    }

    func check() { run(["--check"], "check") }
    func updateNow() { run([], "update") }

    private func run(_ args: [String], _ kind: String) {
        guard running == nil, model.backendInstalled else { return }
        running = kind
        model.log("[tf-update] \(kind) started")
        Task {
            let tool = Paths.backend.appendingPathComponent("bin/tf-update").path
            let (code, out) = await Shell.run("/bin/bash", [tool] + args, timeout: 1800)
            running = nil
            lastOutput = out
            model.log("[tf-update] \(kind) finished (\(code)): \(out.suffix(600))")
            objectWillChange.send()
            await model.refresh()
            let s = report["summary"].str
            if code == 0 {
                model.toast(.success, kind == "check" ? "TensorFold checked" : "TensorFold updated", s.isEmpty ? "Done." : s, seconds: 7)
            } else {
                model.toast(.warn, kind == "check" ? "Check had a problem" : "Update had a problem",
                            s.isEmpty ? "See the Updates log on the Server tab." : s, seconds: 9)
            }
        }
    }
}
