import Foundation
import Darwin
import IOKit
import IOKit.ps
import SystemConfiguration
import CoreWLAN

/// mach_host_self() adds a send-right reference on every call; take it once.
let hostPort: host_t = mach_host_self()

// MARK: - CPU

final class CPUSampler {
    private var previous: [[UInt32]] = []   // per core: user, system, idle, nice

    func sample() -> CPUStats? {
        var cpuCount: natural_t = 0
        var info: processor_info_array_t?
        var infoCount: mach_msg_type_number_t = 0
        let kr = host_processor_info(hostPort, PROCESSOR_CPU_LOAD_INFO, &cpuCount, &info, &infoCount)
        guard kr == KERN_SUCCESS, let info else { return nil }
        defer {
            vm_deallocate(mach_task_self_,
                          vm_address_t(bitPattern: info),
                          vm_size_t(Int(infoCount) * MemoryLayout<integer_t>.stride))
        }

        let stride = Int(CPU_STATE_MAX)
        var current: [[UInt32]] = []
        current.reserveCapacity(Int(cpuCount))
        for i in 0..<Int(cpuCount) {
            let base = i * stride
            current.append([
                UInt32(bitPattern: info[base + Int(CPU_STATE_USER)]),
                UInt32(bitPattern: info[base + Int(CPU_STATE_SYSTEM)]),
                UInt32(bitPattern: info[base + Int(CPU_STATE_IDLE)]),
                UInt32(bitPattern: info[base + Int(CPU_STATE_NICE)]),
            ])
        }
        defer { previous = current }
        guard previous.count == current.count else { return CPUStats() }

        var perCore: [Double] = []
        var sumUser: UInt64 = 0, sumSys: UInt64 = 0, sumAll: UInt64 = 0
        for (cur, prev) in zip(current, previous) {
            // wrapping subtraction handles 32-bit counter overflow
            let user = UInt64(cur[0] &- prev[0]) + UInt64(cur[3] &- prev[3])
            let sys = UInt64(cur[1] &- prev[1])
            let idle = UInt64(cur[2] &- prev[2])
            let all = user + sys + idle
            perCore.append(all == 0 ? 0 : Double(user + sys) / Double(all))
            sumUser += user; sumSys += sys; sumAll += all
        }
        guard sumAll > 0 else { return CPUStats(perCore: perCore) }
        let u = Double(sumUser) / Double(sumAll)
        let s = Double(sumSys) / Double(sumAll)
        return CPUStats(total: u + s, user: u, system: s, perCore: perCore)
    }
}

// MARK: - Memory

enum MemorySampler {
    static func sample() -> MemoryStats {
        var stats = vm_statistics64()
        var count = mach_msg_type_number_t(MemoryLayout<vm_statistics64>.size / MemoryLayout<integer_t>.size)
        let kr = withUnsafeMutablePointer(to: &stats) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                host_statistics64(hostPort, HOST_VM_INFO64, $0, &count)
            }
        }
        var result = MemoryStats()
        result.total = ProcessInfo.processInfo.physicalMemory
        guard kr == KERN_SUCCESS else { return result }

        let page = UInt64(vm_kernel_page_size)
        let internalPages = UInt64(stats.internal_page_count)
        let purgeable = UInt64(stats.purgeable_count)
        // Activity Monitor: Memory Used = App Memory + Wired + Compressed
        result.app = (internalPages > purgeable ? internalPages - purgeable : 0) * page
        result.wired = UInt64(stats.wire_count) * page
        result.compressed = UInt64(stats.compressor_page_count) * page
        result.cached = (UInt64(stats.external_page_count) + purgeable) * page
        result.used = min(result.total, result.app + result.wired + result.compressed)

        var swap = xsw_usage()
        var size = MemoryLayout<xsw_usage>.size
        if sysctlbyname("vm.swapusage", &swap, &size, nil, 0) == 0 {
            result.swapUsed = swap.xsu_used
            result.swapTotal = swap.xsu_total
        }

        var level: Int32 = 1
        var lsize = MemoryLayout<Int32>.size
        if sysctlbyname("kern.memorystatus_vm_pressure_level", &level, &lsize, nil, 0) == 0 {
            result.pressureLevel = Int(level)
        }
        return result
    }
}

// MARK: - Disk

final class DiskSampler {
    private var prevCounters: [UInt64: (UInt64, UInt64)] = [:]   // registry entry ID -> (read, write)
    private var prevTime: TimeInterval = 0
    private let lock = NSLock()
    private var cachedVolumes: [VolumeInfo] = []
    private var lastVolumeScan: TimeInterval = -.infinity
    private var scanInFlight = false
    private static let scanQueue = DispatchQueue(label: "Glance.volumeScan", qos: .utility)

    /// `blockingVolumeScan` is for the CLI dump; the app scans volumes off the main thread.
    func sample(blockingVolumeScan: Bool = false) -> DiskStats {
        let now = ProcessInfo.processInfo.systemUptime
        var stats = DiskStats()

        // Volume capacity changes slowly; rescan at most every 10s, in the background
        // so a stalled external mount can never freeze the UI.
        if blockingVolumeScan {
            let v = Self.scanVolumes()
            lock.withLock { cachedVolumes = v }
        } else if now - lastVolumeScan > 10 && !lock.withLock({ scanInFlight }) {
            lastVolumeScan = now
            lock.withLock { scanInFlight = true }
            Self.scanQueue.async { [weak self] in
                let v = Self.scanVolumes()
                guard let self else { return }
                self.lock.withLock {
                    self.cachedVolumes = v
                    self.scanInFlight = false
                }
            }
        }
        stats.volumes = lock.withLock { cachedVolumes }

        // Per-driver deltas: adding/ejecting a disk doesn't distort the rate,
        // and a failed IOKit query keeps the previous baseline.
        guard let counters = Self.ioCounters() else { return stats }
        if prevTime > 0, now > prevTime {
            let dt = now - prevTime
            var r: UInt64 = 0, w: UInt64 = 0
            for (id, cur) in counters {
                guard let p = prevCounters[id] else { continue }
                if cur.0 >= p.0 { r += cur.0 - p.0 }
                if cur.1 >= p.1 { w += cur.1 - p.1 }
            }
            stats.readRate = Double(r) / dt
            stats.writeRate = Double(w) / dt
        }
        prevCounters = counters
        prevTime = now
        return stats
    }

    static func scanVolumes() -> [VolumeInfo] {
        // Prefetch only cheap flags; capacity is queried after filtering out non-local mounts,
        // since asking a dead SMB/NFS share for free space can block for a long time.
        let flagKeys: [URLResourceKey] = [.volumeIsLocalKey, .volumeIsRootFileSystemKey,
                                          .volumeIsInternalKey, .volumeIsBrowsableKey]
        let capKeys: Set<URLResourceKey> = [.volumeNameKey, .volumeTotalCapacityKey,
                                            .volumeAvailableCapacityForImportantUsageKey,
                                            .volumeAvailableCapacityKey]
        let urls = FileManager.default.mountedVolumeURLs(includingResourceValuesForKeys: flagKeys,
                                                         options: [.skipHiddenVolumes]) ?? []
        var result: [VolumeInfo] = []
        for url in urls {
            guard let f = try? url.resourceValues(forKeys: Set(flagKeys)) else { continue }
            if f.volumeIsLocal == false { continue }
            let isRoot = f.volumeIsRootFileSystem ?? (url.path == "/")
            // root + external/removable volumes only (skip internal system sub-volumes)
            if !isRoot && (f.volumeIsInternal ?? false) { continue }
            if f.volumeIsBrowsable == false { continue }
            guard let v = try? url.resourceValues(forKeys: capKeys),
                  let total = v.volumeTotalCapacity, total > 0 else { continue }
            let avail: Int64 = v.volumeAvailableCapacityForImportantUsage
                ?? Int64(v.volumeAvailableCapacity ?? 0)
            result.append(VolumeInfo(path: url.path,
                                     name: v.volumeName ?? url.lastPathComponent,
                                     total: UInt64(total),
                                     available: UInt64(max(0, min(avail, Int64(total)))),
                                     isRoot: isRoot))
        }
        return result.sorted { ($0.isRoot ? 0 : 1, $0.name) < ($1.isRoot ? 0 : 1, $1.name) }
    }

    /// Bytes read/written per block storage driver, keyed by registry entry ID. nil on IOKit failure.
    static func ioCounters() -> [UInt64: (UInt64, UInt64)]? {
        var iterator: io_iterator_t = 0
        guard IOServiceGetMatchingServices(kIOMainPortDefault,
                                           IOServiceMatching("IOBlockStorageDriver"),
                                           &iterator) == KERN_SUCCESS else { return nil }
        defer { IOObjectRelease(iterator) }
        var result: [UInt64: (UInt64, UInt64)] = [:]
        var service = IOIteratorNext(iterator)
        while service != 0 {
            var entryID: UInt64 = 0
            if IORegistryEntryGetRegistryEntryID(service, &entryID) == KERN_SUCCESS,
               let prop = IORegistryEntryCreateCFProperty(service, "Statistics" as CFString,
                                                          kCFAllocatorDefault, 0)?.takeRetainedValue(),
               let dict = prop as? [String: Any] {
                result[entryID] = ((dict["Bytes (Read)"] as? NSNumber)?.uint64Value ?? 0,
                                   (dict["Bytes (Write)"] as? NSNumber)?.uint64Value ?? 0)
            }
            IOObjectRelease(service)
            service = IOIteratorNext(iterator)
        }
        return result
    }
}

// MARK: - Network

final class NetworkSampler {
    private struct Counter { var ibytes: UInt64; var obytes: UInt64; var baudrate: UInt64; var flags: Int32 }
    private struct HWPort { var bsd: String; var name: String; var kind: NetKind }

    private var prev: [String: Counter] = [:]
    private var prevTime: TimeInterval = 0
    private var ports: [HWPort] = []
    private var lastPortScan: TimeInterval = 0
    private var lastStats = NetworkStats()

    func sample() -> NetworkStats {
        let now = ProcessInfo.processInfo.systemUptime
        if now - lastPortScan > 30 || ports.isEmpty {
            ports = Self.scanPorts()
            lastPortScan = now
        }
        // On a failed read keep the previous baseline and report the last known interfaces.
        guard let counters = Self.readCounters() else { return lastStats }
        let addrs = Self.readAddresses()
        let dt = prevTime > 0 ? now - prevTime : 0

        var stats = NetworkStats()
        for port in ports {
            guard let c = counters[port.bsd] else { continue }
            let running = (c.flags & IFF_UP) != 0 && (c.flags & IFF_RUNNING) != 0
            let a = addrs[port.bsd] ?? ([], [])
            var iface = NetInterface(bsdName: port.bsd, displayName: port.name, kind: port.kind,
                                     isActive: running && !(a.0.isEmpty && a.1.isEmpty),
                                     ipv4: a.0, ipv6: a.1, linkSpeed: c.baudrate,
                                     rxTotal: c.ibytes, txTotal: c.obytes)
            if let p = prev[port.bsd], dt > 0 {
                iface.rxRate = c.ibytes >= p.ibytes ? Double(c.ibytes - p.ibytes) / dt : 0
                iface.txRate = c.obytes >= p.obytes ? Double(c.obytes - p.obytes) / dt : 0
            }
            stats.rxRate += iface.rxRate
            stats.txRate += iface.txRate
            // Always show Wi-Fi; show Ethernet only when it has a live link.
            if port.kind == .wifi || iface.isActive {
                stats.interfaces.append(iface)
            }
        }
        stats.interfaces.sort { ($0.kind == .wifi ? 0 : 1, $0.bsdName) < ($1.kind == .wifi ? 0 : 1, $1.bsdName) }
        stats.wifi = Self.wifiInfo()
        if let primary = Self.primaryInterface() {
            stats.primaryKind = ports.first(where: { $0.bsd == primary })?.kind
        }
        prev = counters
        prevTime = now
        lastStats = stats
        return stats
    }

    /// BSD name of the interface carrying the default route ("State:/Network/Global/IPv4").
    private static func primaryInterface() -> String? {
        guard let store = SCDynamicStoreCreate(nil, "Glance" as CFString, nil, nil) else { return nil }
        for key in ["State:/Network/Global/IPv4", "State:/Network/Global/IPv6"] {
            if let dict = SCDynamicStoreCopyValue(store, key as CFString) as? [String: Any],
               let name = dict["PrimaryInterface"] as? String {
                return name
            }
        }
        return nil
    }

    private static func scanPorts() -> [HWPort] {
        guard let all = SCNetworkInterfaceCopyAll() as? [SCNetworkInterface] else { return [] }
        let wifiType = kSCNetworkInterfaceTypeIEEE80211 as String
        let ethType = kSCNetworkInterfaceTypeEthernet as String
        var result: [HWPort] = []
        for i in all {
            guard let bsd = SCNetworkInterfaceGetBSDName(i) as String?,
                  let type = SCNetworkInterfaceGetInterfaceType(i) as String? else { continue }
            let name = (SCNetworkInterfaceGetLocalizedDisplayName(i) as String?) ?? bsd
            if type == wifiType {
                result.append(HWPort(bsd: bsd, name: name, kind: .wifi))
            } else if type == ethType {
                result.append(HWPort(bsd: bsd, name: name, kind: .ethernet))
            }
        }
        return result
    }

    /// 64-bit interface counters via sysctl NET_RT_IFLIST2 (getifaddrs counters wrap at 4GB).
    private static func readCounters() -> [String: Counter]? {
        var mib: [Int32] = [CTL_NET, PF_ROUTE, 0, 0, NET_RT_IFLIST2, 0]
        var len = 0
        var buf: [UInt8] = []
        var ok = false
        // The table can grow between the size query and the read (VPN/AWDL toggling) -> ENOMEM; retry with slack.
        for _ in 0..<3 {
            guard sysctl(&mib, 6, nil, &len, nil, 0) == 0, len > 0 else { return nil }
            len += len / 8
            buf = [UInt8](repeating: 0, count: len)
            if sysctl(&mib, 6, &buf, &len, nil, 0) == 0 { ok = true; break }
            if errno != ENOMEM { return nil }
        }
        guard ok else { return nil }

        var result: [String: Counter] = [:]
        buf.withUnsafeBytes { raw in
            var offset = 0
            while offset + MemoryLayout<if_msghdr>.size <= len {
                let hdr = raw.loadUnaligned(fromByteOffset: offset, as: if_msghdr.self)
                let msglen = Int(hdr.ifm_msglen)
                if msglen <= 0 { break }
                if Int32(hdr.ifm_type) == RTM_IFINFO2,
                   offset + MemoryLayout<if_msghdr2>.size <= len {
                    let m = raw.loadUnaligned(fromByteOffset: offset, as: if_msghdr2.self)
                    var nameBuf = [CChar](repeating: 0, count: Int(IF_NAMESIZE) + 1)
                    if if_indextoname(UInt32(m.ifm_index), &nameBuf) != nil {
                        let name = String(cString: nameBuf)
                        result[name] = Counter(ibytes: m.ifm_data.ifi_ibytes,
                                               obytes: m.ifm_data.ifi_obytes,
                                               baudrate: m.ifm_data.ifi_baudrate,
                                               flags: m.ifm_flags)
                    }
                }
                offset += msglen
            }
        }
        return result
    }

    private static func readAddresses() -> [String: ([String], [String])] {
        var result: [String: ([String], [String])] = [:]
        var ifap: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&ifap) == 0, let first = ifap else { return result }
        defer { freeifaddrs(ifap) }
        for ptr in sequence(first: first, next: { $0.pointee.ifa_next }) {
            guard let sa = ptr.pointee.ifa_addr else { continue }
            let family = Int32(sa.pointee.sa_family)
            guard family == AF_INET || family == AF_INET6 else { continue }
            var host = [CChar](repeating: 0, count: Int(NI_MAXHOST))
            guard getnameinfo(sa, socklen_t(sa.pointee.sa_len), &host, socklen_t(host.count),
                              nil, 0, NI_NUMERICHOST) == 0 else { continue }
            let name = String(cString: ptr.pointee.ifa_name)
            var addr = String(cString: host)
            if let pct = addr.firstIndex(of: "%") { addr = String(addr[..<pct]) }
            var entry = result[name] ?? ([], [])
            if family == AF_INET {
                entry.0.append(addr)
            } else if !addr.lowercased().hasPrefix("fe80") {
                entry.1.append(addr)   // skip link-local IPv6
            }
            result[name] = entry
        }
        return result
    }

    private static func wifiInfo() -> WiFiInfo? {
        guard let iface = CWWiFiClient.shared().interface(), let name = iface.interfaceName else { return nil }
        let channel = iface.wlanChannel()
        var band: String?
        switch channel?.channelBand {
        case .band2GHz: band = "2.4GHz"
        case .band5GHz: band = "5GHz"
        case .band6GHz: band = "6GHz"
        default: band = nil
        }
        var phy: String?
        switch iface.activePHYMode() {
        case .mode11a: phy = "802.11a"
        case .mode11b: phy = "802.11b"
        case .mode11g: phy = "802.11g"
        case .mode11n: phy = "Wi-Fi 4 (n)"
        case .mode11ac: phy = "Wi-Fi 5 (ac)"
        case .mode11ax: phy = "Wi-Fi 6 (ax)"
        case .mode11be: phy = "Wi-Fi 7 (be)"
        default: phy = nil
        }
        return WiFiInfo(interfaceName: name,
                        powerOn: iface.powerOn(),
                        ssid: iface.ssid(),
                        rssi: iface.rssiValue(),
                        noise: iface.noiseMeasurement(),
                        txRate: iface.transmitRate(),
                        channel: channel?.channelNumber,
                        band: band,
                        phyMode: phy)
    }
}

// MARK: - Bluetooth

/// Uses `system_profiler SPBluetoothDataType -json`: fast (cached by bluetoothd),
/// includes AirPods L/R/Case battery, and needs no Bluetooth TCC permission.
/// Blocking — call off the main thread.
enum BluetoothSampler {
    /// Returns nil if system_profiler failed or timed out (caller keeps last good value).
    static func sample() -> BluetoothStats? {
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: "/usr/sbin/system_profiler")
        proc.arguments = ["SPBluetoothDataType", "-json"]
        let pipe = Pipe()
        proc.standardOutput = pipe
        proc.standardError = FileHandle.nullDevice
        do { try proc.run() } catch { return nil }
        // Watchdog: if bluetoothd is wedged, system_profiler may never exit.
        DispatchQueue.global().asyncAfter(deadline: .now() + 15) {
            if proc.isRunning { proc.terminate() }
        }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        proc.waitUntilExit()
        guard proc.terminationStatus == 0 else { return nil }
        return parse(data)
    }

    static func parse(_ data: Data) -> BluetoothStats {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let arr = root["SPBluetoothDataType"] as? [[String: Any]],
              let bt = arr.first else { return BluetoothStats() }
        var stats = BluetoothStats()
        stats.available = true
        if let ctrl = bt["controller_properties"] as? [String: Any] {
            stats.poweredOn = (ctrl["controller_state"] as? String) == "attrib_on"
        }
        stats.connected = devices(bt["device_connected"], connected: true)
        stats.paired = devices(bt["device_not_connected"], connected: false)
        return stats
    }

    private static func devices(_ any: Any?, connected: Bool) -> [BTDevice] {
        guard let list = any as? [[String: Any]] else { return [] }
        var result: [BTDevice] = []
        for item in list {
            for (name, value) in item {
                let p = value as? [String: Any] ?? [:]
                var batteries: [BTBattery] = []
                let keys: [(String, String)] = [
                    ("device_batteryLevelMain", "배터리"),
                    ("device_batteryLevel", "배터리"),
                    ("device_batteryLevelLeft", "L"),
                    ("device_batteryLevelRight", "R"),
                    ("device_batteryLevelCase", "케이스"),
                ]
                for (key, label) in keys where !batteries.contains(where: { $0.label == label }) {
                    if let s = p[key] as? String,
                       let v = Int(s.trimmingCharacters(in: CharacterSet(charactersIn: "% "))) {
                        batteries.append(BTBattery(label: label, percent: v))
                    }
                }
                result.append(BTDevice(name: name,
                                       address: p["device_address"] as? String ?? "",
                                       minorType: p["device_minorType"] as? String ?? "",
                                       connected: connected,
                                       batteries: batteries))
            }
        }
        return result.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }
}

// MARK: - Battery

enum BatterySampler {
    static func sample() -> BatteryStats {
        var stats = BatteryStats()
        // Public power-source API: percent, charging state, time estimates.
        if let info = IOPSCopyPowerSourcesInfo()?.takeRetainedValue(),
           let list = IOPSCopyPowerSourcesList(info)?.takeRetainedValue() as? [CFTypeRef] {
            for ps in list {
                guard let d = IOPSGetPowerSourceDescription(info, ps)?.takeUnretainedValue() as? [String: Any],
                      (d[kIOPSTypeKey] as? String) == kIOPSInternalBatteryType else { continue }
                stats.present = true
                let cur = d[kIOPSCurrentCapacityKey] as? Int ?? 0
                let max = d[kIOPSMaxCapacityKey] as? Int ?? 100
                let pct = max > 0 ? Int((Double(cur) / Double(max) * 100).rounded()) : cur
                stats.percent = Swift.min(100, Swift.max(0, pct))   // integer 0...100
                stats.isCharging = d[kIOPSIsChargingKey] as? Bool ?? false
                stats.isCharged = d[kIOPSIsChargedKey] as? Bool ?? false
                stats.onAC = (d[kIOPSPowerSourceStateKey] as? String) == kIOPSACPowerValue
                if let t = d[kIOPSTimeToEmptyKey] as? Int, t > 0 { stats.timeToEmpty = t }
                if let t = d[kIOPSTimeToFullChargeKey] as? Int, t > 0 { stats.timeToFull = t }
            }
        }
        guard stats.present else { return stats }

        // AppleSmartBattery registry entry: cycles, health, temperature, power draw, adapter.
        let service = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("AppleSmartBattery"))
        guard service != 0 else { return stats }
        defer { IOObjectRelease(service) }
        // Read individual keys; the full dictionary carries large telemetry blobs.
        func prop(_ k: String) -> Any? {
            IORegistryEntryCreateCFProperty(service, k as CFString, kCFAllocatorDefault, 0)?.takeRetainedValue()
        }
        func num(_ k: String) -> NSNumber? { prop(k) as? NSNumber }
        stats.cycleCount = num("CycleCount")?.intValue
        if let design = num("DesignCapacity")?.doubleValue, design > 0,
           let full = (num("NominalChargeCapacity") ?? num("AppleRawMaxCapacity"))?.doubleValue {
            stats.health = min(1, full / design)
        }
        if let t = num("Temperature")?.doubleValue, t > 0 { stats.temperature = t / 100 }   // centi-°C
        if let mv = num("Voltage")?.doubleValue,
           let ma = (num("InstantAmperage") ?? num("Amperage"))?.int64Value {          // signed, stored as 64-bit
            let w = mv * Double(ma) / 1_000_000
            stats.watts = abs(w) < 0.05 ? 0 : w
        }
        if let adapter = prop("AdapterDetails") as? [String: Any] {
            stats.adapterWatts = (adapter["Watts"] as? NSNumber)?.intValue
            stats.adapterName = (adapter["Name"] as? String)?.trimmingCharacters(in: .whitespaces)
        }
        return stats
    }
}

// MARK: - Temperature

/// Apple Silicon has no public temperature API. This reads the same HID thermal sensors
/// that `powermetrics`/Stats use, via IOKit symbols resolved at runtime (no root needed).
/// If the symbols or sensors are missing, `available` stays false and the UI hides it.
final class TemperatureSampler {
    private typealias CreateFn = @convention(c) (CFAllocator?) -> Unmanaged<AnyObject>?
    private typealias SetMatchingFn = @convention(c) (AnyObject, CFDictionary) -> Int32
    private typealias CopyServicesFn = @convention(c) (AnyObject) -> Unmanaged<CFArray>?
    private typealias CopyPropertyFn = @convention(c) (AnyObject, CFString) -> Unmanaged<CFTypeRef>?
    private typealias CopyEventFn = @convention(c) (AnyObject, Int64, Int32, Int64) -> Unmanaged<CFTypeRef>?
    private typealias GetFloatFn = @convention(c) (CFTypeRef, Int32) -> Double

    private let kTemperatureEvent: Int64 = 15
    private let kTemperatureField: Int32 = 15 << 16

    private var client: AnyObject?
    private var copyEvent: CopyEventFn?
    private var getFloat: GetFloatFn?
    private var dieSensors: [AnyObject] = []
    private var ssdSensors: [AnyObject] = []
    private var batterySensors: [AnyObject] = []

    init() {
        guard let h = dlopen("/System/Library/Frameworks/IOKit.framework/IOKit", RTLD_NOW),
              let pCreate = dlsym(h, "IOHIDEventSystemClientCreate"),
              let pMatch = dlsym(h, "IOHIDEventSystemClientSetMatching"),
              let pServices = dlsym(h, "IOHIDEventSystemClientCopyServices"),
              let pProp = dlsym(h, "IOHIDServiceClientCopyProperty"),
              let pEvent = dlsym(h, "IOHIDServiceClientCopyEvent"),
              let pFloat = dlsym(h, "IOHIDEventGetFloatValue") else { return }
        let create = unsafeBitCast(pCreate, to: CreateFn.self)
        let setMatching = unsafeBitCast(pMatch, to: SetMatchingFn.self)
        let copyServices = unsafeBitCast(pServices, to: CopyServicesFn.self)
        let copyProperty = unsafeBitCast(pProp, to: CopyPropertyFn.self)
        copyEvent = unsafeBitCast(pEvent, to: CopyEventFn.self)
        getFloat = unsafeBitCast(pFloat, to: GetFloatFn.self)

        guard let c = create(kCFAllocatorDefault)?.takeRetainedValue() else { return }
        client = c
        // Apple vendor usage page 0xff00, usage 5 = temperature sensors
        _ = setMatching(c, ["PrimaryUsagePage": 0xff00, "PrimaryUsage": 5] as CFDictionary)
        guard let services = copyServices(c)?.takeRetainedValue() as? [AnyObject] else { return }
        var seen = Set<String>()
        for s in services {
            guard let name = copyProperty(s, "Product" as CFString)?.takeRetainedValue() as? String else { continue }
            // Each physical sensor is published ~3 times; distinct sensors can share a name (battery gauges).
            let location = (copyProperty(s, "LocationID" as CFString)?.takeRetainedValue() as? NSNumber)?.stringValue ?? ""
            guard seen.insert(name + "#" + location).inserted else { continue }
            if name.hasPrefix("PMU") && name.contains("tdie") { dieSensors.append(s) }          // SoC die (CPU/GPU clusters)
            else if name.hasPrefix("NAND") { ssdSensors.append(s) }
            else if name.hasPrefix("gas gauge battery") { batterySensors.append(s) }
        }
    }

    private func read(_ sensors: [AnyObject]) -> [Double] {
        guard let copyEvent, let getFloat else { return [] }
        return sensors.compactMap { s in
            guard let ev = copyEvent(s, kTemperatureEvent, 0, 0)?.takeRetainedValue() else { return nil }
            let v = getFloat(ev, kTemperatureField)
            return (1...130).contains(v) ? v : nil     // drop uncalibrated/garbage readings
        }
    }

    func sample() -> TemperatureStats {
        var stats = TemperatureStats()
        let die = read(dieSensors)
        if !die.isEmpty {
            stats.available = true
            stats.cpuAverage = die.reduce(0, +) / Double(die.count)
            stats.cpuMax = die.max() ?? 0
        }
        stats.ssd = read(ssdSensors).max()
        let bat = read(batterySensors)
        stats.battery = bat.isEmpty ? nil : bat.reduce(0, +) / Double(bat.count)
        return stats
    }
}
