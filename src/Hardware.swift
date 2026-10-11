import Foundation
import IOKit
import Metal

/// One reading of this Mac. Every value is optional: anything macOS does not report stays nil and shows as "–".
struct HardwareSample {
    var cpu: Double?               // % of all cores
    var memUsed: Double?           // bytes: app memory + wired + compressed (Activity Monitor's "Memory Used")
    var memTotal: Double?
    var pressure: Int?             // 1 normal, 2 warning, 4 critical
    var swapUsed: Double?
    var swapTotal: Double?
    var gpuUtil: Double?           // % (IOAccelerator "Device Utilization %")
    var gpuMem: Double?            // bytes the GPU has in use
    var diskRead: Double?          // MB/s
    var diskWrite: Double?
    var thermal: Int = 0           // ProcessInfo.ThermalState raw value: 0 nominal … 3 critical
    var engineFootprint: Double?   // bytes, the engine process's physical footprint
}

/// Static facts about this Mac, read once.
struct MacFacts {
    let chip: String
    let gpuCores: Int?
    let pCores: Int?
    let eCores: Int?
    let threads: Int
    let memory: Double
    let gpuBudget: Double?         // Metal's recommendedMaxWorkingSetSize
    let os: String

    static let current: MacFacts = {
        let mtl = MTLCreateSystemDefaultDevice()
        let v = ProcessInfo.processInfo.operatingSystemVersion
        return MacFacts(
            chip: Shell.sysctl("machdep.cpu.brand_string") ?? "Apple silicon",
            gpuCores: HardwareMonitor.gpuCoreCount(),
            pCores: Shell.sysctlInt("hw.perflevel0.physicalcpu").map(Int.init),
            eCores: Shell.sysctlInt("hw.perflevel1.physicalcpu").map(Int.init),
            threads: ProcessInfo.processInfo.activeProcessorCount,
            memory: Double(ProcessInfo.processInfo.physicalMemory),
            gpuBudget: mtl.map { Double($0.recommendedMaxWorkingSetSize) },
            os: "macOS \(v.majorVersion).\(v.minorVersion)" + (v.patchVersion > 0 ? ".\(v.patchVersion)" : ""))
    }()

    var coresText: String {
        if let p = pCores, let e = eCores { return "\(p + e) cores (\(p) performance, \(e) efficiency)" }
        return "\(threads) cores"
    }
}

final class HardwareMonitor {
    private var lastTicks: [UInt32]?
    private var lastDisk: (read: Double, write: Double, at: Date)?

    func sample(enginePid: Int?) -> HardwareSample {
        var s = HardwareSample()
        s.cpu = cpuPercent()
        let (used, total) = memory()
        s.memUsed = used; s.memTotal = total
        s.pressure = Shell.sysctlInt("kern.memorystatus_vm_pressure_level").map(Int.init)
        (s.swapUsed, s.swapTotal) = swap()
        (s.gpuUtil, s.gpuMem) = gpu()
        (s.diskRead, s.diskWrite) = disk()
        s.thermal = ProcessInfo.processInfo.thermalState.rawValue
        if let pid = enginePid { s.engineFootprint = footprint(pid: Int32(pid)) }
        return s
    }

    // MARK: CPU

    private func cpuPercent() -> Double? {
        var count: natural_t = 0
        var info: processor_info_array_t?
        var infoCount: mach_msg_type_number_t = 0
        guard host_processor_info(mach_host_self(), PROCESSOR_CPU_LOAD_INFO, &count, &info, &infoCount) == KERN_SUCCESS,
              let info else { return nil }
        defer { vm_deallocate(mach_task_self_, vm_address_t(UInt(bitPattern: info)), vm_size_t(Int(infoCount) * MemoryLayout<integer_t>.stride)) }
        var ticks: [UInt32] = []
        for i in 0..<Int(infoCount) { ticks.append(UInt32(bitPattern: info[i])) }
        defer { lastTicks = ticks }
        guard let prev = lastTicks, prev.count == ticks.count else { return nil }
        var busy: Double = 0, all: Double = 0
        let n = Int(CPU_STATE_MAX)
        for cpu in 0..<Int(count) {
            for state in 0..<n {
                let d = Double(ticks[cpu * n + state] &- prev[cpu * n + state])
                all += d
                if state != Int(CPU_STATE_IDLE) { busy += d }
            }
        }
        return all > 0 ? 100 * busy / all : nil
    }

    // MARK: memory

    private func memory() -> (Double?, Double?) {
        let total = Double(ProcessInfo.processInfo.physicalMemory)
        var stats = vm_statistics64()
        var count = mach_msg_type_number_t(MemoryLayout<vm_statistics64>.stride / MemoryLayout<integer_t>.stride)
        let ok = withUnsafeMutablePointer(to: &stats) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) { host_statistics64(mach_host_self(), HOST_VM_INFO64, $0, &count) }
        }
        guard ok == KERN_SUCCESS else { return (nil, total) }
        let page = Double(vm_kernel_page_size)
        let app = Double(stats.internal_page_count) - Double(stats.purgeable_count)
        let used = (app + Double(stats.wire_count) + Double(stats.compressor_page_count)) * page
        return (max(0, used), total)
    }

    private func swap() -> (Double?, Double?) {
        var usage = xsw_usage()
        var size = MemoryLayout<xsw_usage>.size
        guard sysctlbyname("vm.swapusage", &usage, &size, nil, 0) == 0 else { return (nil, nil) }
        return (Double(usage.xsu_used), Double(usage.xsu_total))
    }

    private func footprint(pid: Int32) -> Double? {
        var info = rusage_info_v4()
        let r = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: rusage_info_t?.self, capacity: 1) { proc_pid_rusage(pid, RUSAGE_INFO_V4, $0) }
        }
        return r == 0 ? Double(info.ri_phys_footprint) : nil
    }

    // MARK: GPU (IOAccelerator's performance statistics; no root needed)

    private func gpu() -> (Double?, Double?) {
        var util: Double?, mem: Double?
        forEachService("IOAccelerator") { svc in
            guard let stats = IORegistryEntryCreateCFProperty(svc, "PerformanceStatistics" as CFString, kCFAllocatorDefault, 0)?
                .takeRetainedValue() as? [String: Any] else { return }
            if let u = (stats["Device Utilization %"] as? NSNumber)?.doubleValue { util = max(util ?? 0, u) }
            if let m = (stats["In use system memory"] as? NSNumber)?.doubleValue { mem = (mem ?? 0) + m }
        }
        return (util, mem)
    }

    static func gpuCoreCount() -> Int? {
        var cores: Int?
        HardwareMonitor().forEachService("IOAccelerator") { svc in
            if let n = IORegistryEntryCreateCFProperty(svc, "gpu-core-count" as CFString, kCFAllocatorDefault, 0)?
                .takeRetainedValue() as? NSNumber { cores = n.intValue }
        }
        return cores
    }

    // MARK: disk (IOBlockStorageDriver statistics, summed over drives)

    private func disk() -> (Double?, Double?) {
        var read = 0.0, write = 0.0, found = false
        forEachService("IOBlockStorageDriver") { svc in
            guard let stats = IORegistryEntryCreateCFProperty(svc, "Statistics" as CFString, kCFAllocatorDefault, 0)?
                .takeRetainedValue() as? [String: Any] else { return }
            found = true
            read += (stats["Bytes (Read)"] as? NSNumber)?.doubleValue ?? 0
            write += (stats["Bytes (Write)"] as? NSNumber)?.doubleValue ?? 0
        }
        guard found else { return (nil, nil) }
        let now = Date()
        defer { lastDisk = (read, write, now) }
        guard let last = lastDisk else { return (nil, nil) }
        let dt = now.timeIntervalSince(last.at)
        guard dt > 0.2 else { return (nil, nil) }
        return (max(0, read - last.read) / dt / 1_048_576, max(0, write - last.write) / dt / 1_048_576)
    }

    private func forEachService(_ cls: String, _ body: (io_object_t) -> Void) {
        var iter: io_iterator_t = 0
        guard IOServiceGetMatchingServices(kIOMainPortDefault, IOServiceMatching(cls), &iter) == KERN_SUCCESS else { return }
        defer { IOObjectRelease(iter) }
        while case let svc = IOIteratorNext(iter), svc != 0 {
            body(svc)
            IOObjectRelease(svc)
        }
    }
}
