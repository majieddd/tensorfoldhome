import AppKit
import Foundation

/// Where things live. The backend (engine, gateway, Open WebUI, updater) is shared with `tfctl`; the app keeps its own
/// settings, chat and logs next to it.
enum Paths {
    static let home = FileManager.default.homeDirectoryForCurrentUser
    static let backend = home.appendingPathComponent("Library/Application Support/TensorFoldLauncher")
    static let app = home.appendingPathComponent("Library/Application Support/TensorFoldHome")
    static let logs = app.appendingPathComponent("logs")
    static let updates = app.appendingPathComponent("updates")
    static var tfctl: String { backend.appendingPathComponent("bin/tfctl").path }
    static var backendLogs: URL { backend.appendingPathComponent("logs") }
    static var configEnv: URL { backend.appendingPathComponent("config.env") }
    static var modelsConf: URL { backend.appendingPathComponent("models.conf") }
    static var apiKey: URL { backend.appendingPathComponent("state/api_key") }

    static func ensure() {
        for d in [app, logs, updates] { try? FileManager.default.createDirectory(at: d, withIntermediateDirectories: true) }
    }

    /// One line in logs/app.log (kept under 1 MB).
    static func diag(_ s: String) {
        ensure()
        let url = logs.appendingPathComponent("app.log")
        let line = "\(ISO8601DateFormatter().string(from: Date())) \(s)\n"
        if let attrs = try? FileManager.default.attributesOfItem(atPath: url.path), (attrs[.size] as? Int ?? 0) > 1_000_000 {
            try? FileManager.default.removeItem(at: url)
        }
        if let h = try? FileHandle(forWritingTo: url) {
            h.seekToEndOfFile(); h.write(Data(line.utf8)); try? h.close()
        } else {
            try? line.write(to: url, atomically: true, encoding: .utf8)
        }
    }
}

/// Loosely typed access to the gateway's JSON (it grows fields over time; the app reads what it knows).
struct J {
    let raw: Any?
    init(_ raw: Any?) { self.raw = raw }
    static func parse(_ data: Data?) -> J { J(data.flatMap { try? JSONSerialization.jsonObject(with: $0) }) }

    subscript(_ key: String) -> J { J((raw as? [String: Any])?[key]) }
    subscript(_ i: Int) -> J { let a = raw as? [Any]; return J(a.flatMap { i < $0.count ? $0[i] : nil }) }
    var array: [J] { (raw as? [Any])?.map { J($0) } ?? [] }
    var dict: [String: J] { ((raw as? [String: Any]) ?? [:]).mapValues { J($0) } }
    var isNull: Bool { raw == nil || raw is NSNull }
    var string: String? {
        if let s = raw as? String { return s }
        if let n = raw as? NSNumber, !(raw is Bool) { return n.stringValue }
        return nil
    }
    var str: String { string ?? "" }
    var double: Double? {
        if let n = raw as? NSNumber { return n.doubleValue }
        if let s = raw as? String { return Double(s) }
        return nil
    }
    var int: Int? { double.map { Int($0) } }
    var bool: Bool { (raw as? Bool) ?? ((raw as? NSNumber)?.boolValue ?? false) }
    var doubles: [Double] { array.compactMap { $0.double } }
}

enum Fmt {
    static let grouped: NumberFormatter = {
        let f = NumberFormatter(); f.numberStyle = .decimal; f.maximumFractionDigits = 0; return f
    }()

    /// 12,345 / 12.3 (digits after the point) / "–" for nothing.
    static func n(_ v: Double?, _ digits: Int = 0) -> String {
        guard let v, v.isFinite else { return "–" }
        if digits == 0 { return grouped.string(from: NSNumber(value: v.rounded())) ?? "\(Int(v))" }
        let f = NumberFormatter(); f.numberStyle = .decimal
        f.minimumFractionDigits = digits; f.maximumFractionDigits = digits
        return f.string(from: NSNumber(value: v)) ?? String(format: "%.\(digits)f", v)
    }
    static func n(_ v: Int?) -> String { n(v.map(Double.init)) }

    static func gb(_ bytes: Double?, _ digits: Int = 1) -> String {
        guard let bytes else { return "–" }
        return n(bytes / 1_073_741_824, digits)
    }

    /// 65536 -> 64K, 1500 -> 1.5K, 300 -> 300
    static func k(_ v: Double?) -> String {
        guard let v else { return "–" }
        if v >= 1024 * 1024 { return n(v / 1_048_576, 1) + "M" }
        if v >= 1000 { return (v.truncatingRemainder(dividingBy: 1024) == 0 ? n(v / 1024) : n(v / 1000, 1)) + "K" }
        return n(v)
    }

    static func duration(_ s: Double) -> String {
        let t = Int(max(0, s))
        return String(format: "%d:%02d:%02d", t / 3600, (t / 60) % 60, t % 60)
    }

    static func time(_ epoch: Double?) -> String {
        guard let epoch else { return "–" }
        let f = DateFormatter(); f.timeStyle = .medium; f.dateStyle = .none
        return plain(f.string(from: Date(timeIntervalSince1970: epoch)))
    }

    /// macOS puts narrow no-break spaces in times ("4:47 PM"); Outfit has no glyph for them.
    static func plain(_ s: String) -> String {
        s.replacingOccurrences(of: "\u{202F}", with: " ").replacingOccurrences(of: "\u{2009}", with: " ")
    }

    static func ago(_ epoch: Double?) -> String {
        guard let epoch else { return "" }
        let s = Date().timeIntervalSince1970 - epoch
        if s < 60 { return "just now" }
        if s < 3600 { return "\(Int(s / 60)) min ago" }
        if s < 86400 { return n(s / 3600, 1) + " h ago" }
        return n(s / 86400, 1) + " days ago"
    }
}

/// Runs a command off the main thread and returns (exit code, output).
enum Shell {
    static func run(_ launchPath: String, _ args: [String], timeout: TimeInterval = 600) async -> (Int32, String) {
        await withCheckedContinuation { cont in
            DispatchQueue.global(qos: .userInitiated).async {
                let p = Process()
                p.executableURL = URL(fileURLWithPath: launchPath)
                p.arguments = args
                var env = ProcessInfo.processInfo.environment
                env["PATH"] = "/opt/homebrew/bin:\(Paths.home.path)/.local/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin"
                p.environment = env
                let pipe = Pipe()
                p.standardOutput = pipe
                p.standardError = pipe
                do { try p.run() } catch { cont.resume(returning: (127, "\(error)")); return }
                let timer = DispatchWorkItem { if p.isRunning { p.terminate() } }
                DispatchQueue.global().asyncAfter(deadline: .now() + timeout, execute: timer)
                let data = pipe.fileHandleForReading.readDataToEndOfFile()
                p.waitUntilExit()
                timer.cancel()
                cont.resume(returning: (p.terminationStatus, String(decoding: data, as: UTF8.self)))
            }
        }
    }

    /// The same, blocking the calling thread (for Quit, which must not wait on the main queue).
    @discardableResult
    static func runSync(_ launchPath: String, _ args: [String], timeout: TimeInterval = 60) -> Int32 {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: launchPath)
        p.arguments = args
        p.standardOutput = FileHandle.nullDevice
        p.standardError = FileHandle.nullDevice
        guard (try? p.run()) != nil else { return 127 }
        let deadline = Date().addingTimeInterval(timeout)
        while p.isRunning && Date() < deadline { Thread.sleep(forTimeInterval: 0.05) }
        if p.isRunning { p.terminate() }
        return p.terminationStatus
    }

    static func tfctl(_ args: String...) async -> (Int32, String) { await run("/bin/bash", [Paths.tfctl] + args) }
    static func tfctl(_ args: [String]) async -> (Int32, String) { await run("/bin/bash", [Paths.tfctl] + args) }

    /// Synchronous sysctl string.
    static func sysctl(_ name: String) -> String? {
        var size = 0
        guard sysctlbyname(name, nil, &size, nil, 0) == 0, size > 0 else { return nil }
        var buf = [CChar](repeating: 0, count: size)
        guard sysctlbyname(name, &buf, &size, nil, 0) == 0 else { return nil }
        return String(cString: buf)
    }

    static func sysctlInt(_ name: String) -> Int64? {
        var v: Int64 = 0
        var size = MemoryLayout<Int64>.size
        if sysctlbyname(name, &v, &size, nil, 0) == 0 { return size == 4 ? Int64(Int32(truncatingIfNeeded: v)) : v }
        var v32: Int32 = 0
        size = MemoryLayout<Int32>.size
        return sysctlbyname(name, &v32, &size, nil, 0) == 0 ? Int64(v32) : nil
    }
}

enum Clip {
    static func copy(_ s: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(s, forType: .string)
    }
}

/// This Mac's IPv4 addresses on the local network (for "Serve the model on the network").
enum Net {
    static func lanAddresses() -> [String] {
        var out: [String] = []
        var ifaddr: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&ifaddr) == 0, let first = ifaddr else { return out }
        defer { freeifaddrs(ifaddr) }
        var p: UnsafeMutablePointer<ifaddrs>? = first
        while let cur = p {
            let flags = Int32(cur.pointee.ifa_flags)
            if let addr = cur.pointee.ifa_addr, addr.pointee.sa_family == UInt8(AF_INET),
               flags & IFF_UP != 0, flags & IFF_LOOPBACK == 0 {
                let name = String(cString: cur.pointee.ifa_name)
                if name.hasPrefix("en") || name.hasPrefix("bridge") {
                    var host = [CChar](repeating: 0, count: Int(NI_MAXHOST))
                    if getnameinfo(addr, socklen_t(addr.pointee.sa_len), &host, socklen_t(host.count), nil, 0, NI_NUMERICHOST) == 0 {
                        let ip = String(cString: host)
                        if !ip.hasPrefix("169.254.") { out.append(ip) }
                    }
                }
            }
            p = cur.pointee.ifa_next
        }
        return Array(Set(out)).sorted()
    }
}

/// Reads a KEY=VALUE file (config.env) and rewrites single keys in place.
struct EnvFile {
    let url: URL
    func read() -> [String: String] {
        guard let text = try? String(contentsOf: url, encoding: .utf8) else { return [:] }
        var out: [String: String] = [:]
        for line in text.split(separator: "\n") {
            let l = line.split(separator: "#", maxSplits: 1, omittingEmptySubsequences: false).first.map(String.init) ?? ""
            guard let eq = l.firstIndex(of: "=") else { continue }
            let k = l[..<eq].trimmingCharacters(in: .whitespaces)
            let v = l[l.index(after: eq)...].trimmingCharacters(in: .whitespaces).trimmingCharacters(in: CharacterSet(charactersIn: "\"'"))
            if !k.isEmpty { out[k] = v }
        }
        return out
    }
    func set(_ key: String, _ value: String) {
        var lines = ((try? String(contentsOf: url, encoding: .utf8)) ?? "").components(separatedBy: "\n")
        if let i = lines.firstIndex(where: { $0.hasPrefix(key + "=") }) { lines[i] = "\(key)=\(value)" }
        else {
            if lines.last == "" { lines.removeLast() }
            lines.append("\(key)=\(value)"); lines.append("")
        }
        try? lines.joined(separator: "\n").write(to: url, atomically: true, encoding: .utf8)
    }
}
