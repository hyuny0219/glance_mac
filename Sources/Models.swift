import Foundation

struct CPUStats {
    var total: Double = 0      // 0...1
    var user: Double = 0
    var system: Double = 0
    var perCore: [Double] = []
}

struct MemoryStats {
    var total: UInt64 = 0
    var used: UInt64 = 0
    var app: UInt64 = 0
    var wired: UInt64 = 0
    var compressed: UInt64 = 0
    var cached: UInt64 = 0
    var swapUsed: UInt64 = 0
    var swapTotal: UInt64 = 0
    /// 1 = normal, 2 = warning, 4 = critical
    var pressureLevel: Int = 1

    var usedFraction: Double { total == 0 ? 0 : Double(used) / Double(total) }
}

struct VolumeInfo: Identifiable {
    var id: String { path }
    var path: String
    var name: String
    var total: UInt64
    var available: UInt64
    var isRoot: Bool

    var used: UInt64 { total > available ? total - available : 0 }
    var usedFraction: Double { total == 0 ? 0 : Double(used) / Double(total) }
}

struct DiskStats {
    var volumes: [VolumeInfo] = []
    var readRate: Double = 0   // bytes/s
    var writeRate: Double = 0

    var root: VolumeInfo? { volumes.first(where: { $0.isRoot }) }
}

enum NetKind: String {
    case wifi = "Wi-Fi"
    case ethernet = "Ethernet"
}

struct NetInterface: Identifiable {
    var id: String { bsdName }
    var bsdName: String
    var displayName: String
    var kind: NetKind
    var isActive: Bool
    var ipv4: [String]
    var ipv6: [String]
    var linkSpeed: UInt64      // bits/s
    var rxRate: Double = 0     // bytes/s
    var txRate: Double = 0
    var rxTotal: UInt64 = 0
    var txTotal: UInt64 = 0
}

struct WiFiInfo {
    var interfaceName: String
    var powerOn: Bool
    var ssid: String?
    var rssi: Int
    var noise: Int
    var txRate: Double          // Mbps
    var channel: Int?
    var band: String?
    var phyMode: String?

    var isConnected: Bool { powerOn && rssi != 0 }
    /// 0...1 signal quality
    var quality: Double {
        guard isConnected else { return 0 }
        return min(1, max(0, Double(rssi + 90) / 40.0))  // -90dBm -> 0, -50dBm -> 1
    }
    var qualityText: String {
        switch rssi {
        case 0: return "-"
        case (-55)...: return "매우 좋음"
        case (-67)...: return "좋음"
        case (-75)...: return "보통"
        default: return "약함"
        }
    }
}

struct NetworkStats {
    var interfaces: [NetInterface] = []
    var wifi: WiFiInfo?
    var rxRate: Double = 0
    var txRate: Double = 0
    /// Kind of the interface macOS currently routes through (nil = offline / other, e.g. VPN-only).
    var primaryKind: NetKind?

    /// SF Symbol for the active connection type.
    var connectionSymbol: String {
        switch primaryKind {
        case .wifi: return "wifi"
        case .ethernet: return "cable.connector"
        case nil: return interfaces.contains(where: \.isActive) ? "network" : "wifi.slash"
        }
    }
    var connectionName: String {
        switch primaryKind {
        case .wifi: return "Wi-Fi"
        case .ethernet: return "Ethernet"
        case nil: return interfaces.contains(where: \.isActive) ? "기타" : "연결 안 됨"
        }
    }
}

struct BTBattery: Hashable {
    var label: String
    var percent: Int
}

struct BTDevice: Identifiable {
    var id: String { address.isEmpty ? name : address }
    var name: String
    var address: String
    var minorType: String
    var connected: Bool
    var batteries: [BTBattery]

    var symbol: String {
        let t = minorType.lowercased()
        let n = name.lowercased()
        if t.contains("headset") || t.contains("headphone") || n.contains("airpods") || n.contains("buds") { return "headphones" }
        if t.contains("keyboard") { return "keyboard" }
        if t.contains("mouse") || n.contains("mouse") { return "computermouse" }
        if t.contains("trackpad") || n.contains("trackpad") { return "rectangle.and.hand.point.up.left" }
        if t.contains("speaker") { return "hifispeaker" }
        if t.contains("phone") { return "iphone" }
        if t.contains("gamepad") || t.contains("controller") { return "gamecontroller" }
        return "dot.radiowaves.left.and.right"
    }
}

struct BluetoothStats {
    var available: Bool = false
    var poweredOn: Bool = false
    var connected: [BTDevice] = []
    var paired: [BTDevice] = []
}

struct Snapshot {
    var cpu = CPUStats()
    var memory = MemoryStats()
    var disk = DiskStats()
    var network = NetworkStats()
    var bluetooth = BluetoothStats()
    var battery = BatteryStats()
    var temperature = TemperatureStats()
}

struct BatteryStats {
    var present: Bool = false
    var percent: Int = 0
    var isCharging: Bool = false
    var isCharged: Bool = false
    var onAC: Bool = false
    /// minutes; nil while macOS is still estimating
    var timeToEmpty: Int?
    var timeToFull: Int?
    var cycleCount: Int?
    /// 0...1, same basis as System Settings "Maximum Capacity"
    var health: Double?
    var temperature: Double?      // °C
    var watts: Double?            // + charging / - discharging
    var adapterWatts: Int?
    var adapterName: String?
}

enum PowerState {
    case battery      // running on battery
    case charging     // plugged in and charging
    case pluggedIn    // plugged in, not charging (full or charge on hold)
}

extension BatteryStats {
    var powerState: PowerState {
        if isCharging { return .charging }
        return onAC ? .pluggedIn : .battery
    }
}

struct TemperatureStats {
    var available: Bool = false
    var cpuAverage: Double = 0    // °C, mean of SoC die sensors
    var cpuMax: Double = 0
    var ssd: Double?
    var battery: Double?
}
