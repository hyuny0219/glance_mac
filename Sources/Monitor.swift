import AppKit
import SwiftUI
import CoreLocation
import ServiceManagement

enum MenuBarStyle: String, CaseIterable, Identifiable {
    case icon, compact, detailed
    var id: String { rawValue }
    var title: String {
        switch self {
        case .icon: return "아이콘만"
        case .compact: return "아이콘과 숫자"
        case .detailed: return "두 줄 상세"
        }
    }
}

struct PanelActions {
    var close: () -> Void = {}
    var openSettings: () -> Void = {}
    var openActivityMonitor: () -> Void = {
        NSWorkspace.shared.open(URL(fileURLWithPath: "/System/Applications/Utilities/Activity Monitor.app"))
    }
    var quit: () -> Void = { NSApp.terminate(nil) }
}

enum StatusMetric: String, CaseIterable, Identifiable {
    case cpu, temperature, memory, disk, network, battery, bluetooth
    var id: String { rawValue }
    var title: String {
        switch self {
        case .cpu: return "CPU 사용률"
        case .temperature: return "CPU 온도"
        case .battery: return "배터리"
        case .memory: return "메모리 사용률"
        case .disk: return "디스크 사용률"
        case .network: return "네트워크 속도"
        case .bluetooth: return "블루투스 연결 수"
        }
    }
    var shortTitle: String {
        switch self {
        case .cpu: return "CPU"
        case .temperature: return "온도"
        case .memory: return "메모리"
        case .disk: return "디스크"
        case .network: return "네트워크"
        case .battery: return "배터리"
        case .bluetooth: return "블루투스"
        }
    }
    var symbol: String {
        switch self {
        case .cpu: return "cpu"
        case .temperature: return "thermometer.medium"
        case .memory: return "memorychip"
        case .disk: return "internaldrive"
        case .network: return "network"
        case .battery: return "battery.100percent"
        case .bluetooth: return "dot.radiowaves.left.and.right"
        }
    }
    var defaultOn: Bool { self == .cpu || self == .temperature || self == .memory || self == .network }
}

@MainActor
final class ResourceMonitor: NSObject, ObservableObject, CLLocationManagerDelegate {
    @Published private(set) var snapshot = Snapshot()
    @Published private(set) var cpuHistory: [Double] = []
    @Published private(set) var rxHistory: [Double] = []
    @Published private(set) var txHistory: [Double] = []
    @Published private(set) var tempHistory: [Double] = []
    @Published private(set) var statusImage = NSImage(systemSymbolName: "gauge.with.dots.needle.33percent",
                                                       accessibilityDescription: "Glance")!

    @Published var enabledMetrics: Set<StatusMetric> {
        didSet {
            UserDefaults.standard.set(enabledMetrics.map(\.rawValue), forKey: "enabledMetrics")
            resetFit()
        }
    }
    @Published var interval: Double {
        didSet {
            UserDefaults.standard.set(interval, forKey: "interval")
            scheduleTimer()
        }
    }
    // UI-only state (kept here because @State needs the SwiftUI macro plugin, absent in Command Line Tools)
    // UI-only state (kept here because @State needs the SwiftUI macro plugin, absent in Command Line Tools)
    /// nil = module grid; otherwise the detail page shown in the panel.
    @Published var page: DetailSection?
    /// id of the element under the mouse (hover highlight).
    @Published var hovered: String?
    @Published var menuBarStyle: MenuBarStyle =
        MenuBarStyle(rawValue: UserDefaults.standard.string(forKey: "menuBarStyle") ?? "") ?? .detailed {
        didSet {
            if persistsSettings { UserDefaults.standard.set(menuBarStyle.rawValue, forKey: "menuBarStyle") }
            resetFit()
        }
    }
    /// false for the CLI snapshot tool so it never touches the user's saved settings.
    var persistsSettings = true

    /// Panel actions, wired up by AppDelegate.
    var actions = PanelActions()

    /// Sections whose hardware is present (temperature/battery may be missing).
    var visibleSections: [DetailSection] {
        DetailSection.allCases.filter {
            switch $0 {
            case .temperature: return snapshot.temperature.available
            case .battery: return snapshot.battery.present
            default: return true
            }
        }
    }

    /// The page actually shown: falls back to the grid if its hardware vanished (sensor dropout).
    var visiblePage: DetailSection? {
        page.flatMap { visibleSections.contains($0) ? $0 : nil }
    }
    @Published private(set) var locationStatus: CLAuthorizationStatus = .notDetermined
    @Published private(set) var launchAtLogin = SMAppService.mainApp.status == .enabled

    private let historyLength = 60
    private let collector = Collector()
    private var tickInFlight = false
    private var timer: Timer?
    private var btTimer: Timer?
    private var btInFlight = false
    private let locationManager = CLLocationManager()

    override init() {
        if let saved = UserDefaults.standard.array(forKey: "enabledMetrics") as? [String] {
            enabledMetrics = Set(saved.compactMap(StatusMetric.init(rawValue:)))
        } else {
            enabledMetrics = Set(StatusMetric.allCases.filter(\.defaultOn))
        }
        let savedInterval = UserDefaults.standard.double(forKey: "interval")
        interval = savedInterval > 0 ? savedInterval : 2
        super.init()
        locationManager.delegate = self
        locationStatus = locationManager.authorizationStatus
    }

    func start() {
        let collector = collector
        Collector.queue.async { collector.prime() }   // prime deltas
        renderStatusImage()
        // First real sample after 1s so rate deltas aren't computed over a few milliseconds.
        DispatchQueue.main.asyncAfter(deadline: .now() + 1) { [weak self] in
            self?.tick()
            self?.scheduleTimer()
        }
        refreshBluetooth()
        let bt = Timer(timeInterval: 10, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.refreshBluetooth() }
        }
        RunLoop.main.add(bt, forMode: .common)
        btTimer = bt
    }

    private func scheduleTimer() {
        timer?.invalidate()
        let t = Timer(timeInterval: interval, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.tick() }
        }
        t.tolerance = interval * 0.1
        RunLoop.main.add(t, forMode: .common)   // keep updating while popover/menu is tracking
        timer = t
    }

    /// Sampling (temperature sensors, CoreWLAN, IOKit) takes ~20ms, so it runs on a
    /// background serial queue; only publishing and rendering happen on the main thread.
    private func tick() {
        guard !tickInFlight else { return }
        tickInFlight = true
        let collector = collector
        Collector.queue.async {
            let r = collector.collect()
            Task { @MainActor in self.apply(r) }
        }
    }

    private func apply(_ r: Collector.Result) {
        tickInFlight = false
        var s = snapshot
        if let c = r.cpu { s.cpu = c }
        s.memory = r.memory
        s.disk = r.disk
        s.network = r.network
        s.battery = r.battery
        s.temperature = r.temperature
        snapshot = s

        append(&cpuHistory, s.cpu.total)
        append(&rxHistory, s.network.rxRate)
        append(&txHistory, s.network.txRate)
        if s.temperature.available { append(&tempHistory, s.temperature.cpuAverage) }
        renderStatusImage()
    }

    private func append(_ arr: inout [Double], _ v: Double) {
        arr.append(v)
        if arr.count > historyLength { arr.removeFirst(arr.count - historyLength) }
    }

    func refreshBluetooth() {
        guard !btInFlight else { return }
        btInFlight = true
        DispatchQueue.global(qos: .utility).async {
            let stats = BluetoothSampler.sample()
            Task { @MainActor in
                self.btInFlight = false
                guard let stats else { return }
                self.snapshot.bluetooth = stats
                self.renderStatusImage()
            }
        }
    }

    // MARK: Status bar image

    /// Metrics dropped (from the end) because the status item didn't fit beside the notch.
    @Published private(set) var hiddenForSpace: [StatusMetric] = []
    private var displayLimit: Int?

    /// Called when the status item would be hidden by the notch: show one metric fewer.
    func shrinkForSpace() {
        let all = StatusMetric.allCases.filter { enabledMetrics.contains($0) }
        let current = displayLimit ?? all.count
        guard current > 0 else { return }
        displayLimit = current - 1
        hiddenForSpace = Array(all.dropFirst(current - 1))
        renderStatusImage()
    }

    /// Try the full set again (settings or screen layout changed).
    func resetFit() {
        displayLimit = nil
        hiddenForSpace = []
        renderStatusImage()
    }

    private func renderStatusImage() {
        var metrics = StatusMetric.allCases.filter { enabledMetrics.contains($0) }
        if let limit = displayLimit { metrics = Array(metrics.prefix(limit)) }
        let scale = NSScreen.main?.backingScaleFactor ?? 2
        let renderer = ImageRenderer(content: StatusBarLabel(style: menuBarStyle, metrics: metrics, snapshot: snapshot))
        renderer.scale = scale
        guard let cg = renderer.cgImage else { return }
        let img = NSImage(cgImage: cg, size: NSSize(width: CGFloat(cg.width) / scale,
                                                    height: CGFloat(cg.height) / scale))
        img.isTemplate = true   // adapts to light/dark menu bar automatically
        img.accessibilityDescription = "Glance"
        statusImage = img
    }

    // MARK: Location (needed by macOS to reveal Wi-Fi SSID)

    func requestLocation() {
        if locationStatus == .notDetermined {
            locationManager.requestWhenInUseAuthorization()
        } else if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_LocationServices") {
            NSWorkspace.shared.open(url)
        }
    }

    nonisolated func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        let status = manager.authorizationStatus
        // Only record the status; the next scheduled tick picks up the SSID.
        // (A full tick here would compute rates over a few ms and pollute history.)
        Task { @MainActor in self.locationStatus = status }
    }

    // MARK: Launch at login

    func setLaunchAtLogin(_ on: Bool) {
        do {
            if on { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
        } catch {
            NSLog("Launch at login change failed: \(error)")
        }
        launchAtLogin = SMAppService.mainApp.status == .enabled
    }
}

/// Owns the samplers; used only from `Collector.queue`.
final class Collector: @unchecked Sendable {   // confined to `queue` (serial)
    static let queue = DispatchQueue(label: "Glance.collect", qos: .utility)

    struct Result {
        var cpu: CPUStats?
        var memory: MemoryStats
        var disk: DiskStats
        var network: NetworkStats
        var battery: BatteryStats
        var temperature: TemperatureStats
    }

    private let cpu = CPUSampler()
    private let disk = DiskSampler()
    private let net = NetworkSampler()
    private lazy var thermal = TemperatureSampler()

    func prime() {
        _ = cpu.sample()
        _ = disk.sample()
        _ = net.sample()
    }

    func collect() -> Result {
        Result(cpu: cpu.sample(),
               memory: MemorySampler.sample(),
               disk: disk.sample(),
               network: net.sample(),
               battery: BatterySampler.sample(),
               temperature: thermal.sample())
    }
}
