import AppKit
import SwiftUI
import Combine
import ServiceManagement

@main
enum Main {
    static func main() {
        if CommandLine.arguments.contains("--dump") {
            Dump.run()
            return
        }
        // `--login-item on|off|status` — register/unregister launch at login from the terminal.
        if let i = CommandLine.arguments.firstIndex(of: "--login-item") {
            let arg = i + 1 < CommandLine.arguments.count ? CommandLine.arguments[i + 1] : "status"
            do {
                if arg == "on" { try SMAppService.mainApp.register() }
                if arg == "off" { try SMAppService.mainApp.unregister() }
            } catch {
                print("error: \(error.localizedDescription)")
            }
            let names: [SMAppService.Status: String] = [.enabled: "enabled", .notRegistered: "notRegistered",
                                                        .requiresApproval: "requiresApproval", .notFound: "notFound"]
            print("login item: \(names[SMAppService.mainApp.status] ?? "unknown")")
            return
        }
        if let i = CommandLine.arguments.firstIndex(of: "--snapshot"), i + 1 < CommandLine.arguments.count {
            MainActor.assumeIsolated { Snapshotter.run(outDir: CommandLine.arguments[i + 1]) }
            return
        }
        let app = NSApplication.shared
        let delegate = AppDelegate()
        app.delegate = delegate
        app.setActivationPolicy(.accessory)   // menu bar only, no Dock icon
        app.run()
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private let monitor = ResourceMonitor()
    private var statusItem: NSStatusItem!
    private var panel: PanelController!
    private var settings: SettingsWindowController!
    private var cancellables = Set<AnyCancellable>()

    func applicationDidFinishLaunching(_ notification: Notification) {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        if let button = statusItem.button {
            button.imagePosition = .imageOnly
            button.target = self
            button.action = #selector(togglePanel(_:))
            button.sendAction(on: [.leftMouseDown, .rightMouseDown])   // menus open on mouse-down
        }

        panel = PanelController(monitor: monitor)
        panel.onVisibilityChange = { [weak self] open in self?.statusItem.button?.highlight(open) }
        settings = SettingsWindowController(monitor: monitor)
        monitor.actions.close = { [weak self] in self?.panel.close() }
        monitor.actions.openSettings = { [weak self] in
            self?.panel.close()
            self?.settings.show()
        }

        monitor.$statusImage
            .sink { [weak self] image in
                self?.statusItem.button?.image = image
                // Let the menu bar lay out the new width, then check the notch.
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { self?.checkNotchFit() }
            }
            .store(in: &cancellables)

        // Space beside the notch can change (displays, other menu bar apps): retry the full set.
        NotificationCenter.default.addObserver(forName: NSApplication.didChangeScreenParametersNotification,
                                               object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.monitor.resetFit() }
        }
        Timer.scheduledTimer(withTimeInterval: 300, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.monitor.resetFit() }
        }

        monitor.start()

        if ProcessInfo.processInfo.environment["RM_DEBUG_OPEN_SETTINGS"] != nil {
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { [weak self] in self?.monitor.actions.openSettings() }
        }
        // Test hook: open the panel shortly after launch (UI check without clicking).
        if ProcessInfo.processInfo.environment["RM_DEBUG_OPEN_PANEL"] != nil {
            DispatchQueue.main.asyncAfter(deadline: .now() + 2.5) { [weak self] in self?.togglePanel(nil) }
            // RM_DEBUG_OPEN_PANEL=<section> also drills into that page.
            if let page = DetailSection(rawValue: ProcessInfo.processInfo.environment["RM_DEBUG_OPEN_PANEL"] ?? "") {
                DispatchQueue.main.asyncAfter(deadline: .now() + 3.5) { [weak self] in self?.monitor.page = page }
            }
        }
    }

    /// macOS hides a status item entirely if it overlaps the camera notch.
    private func checkNotchFit() {
        guard let window = statusItem.button?.window,
              let screen = window.screen ?? NSScreen.main,
              let left = screen.auxiliaryTopLeftArea,
              let right = screen.auxiliaryTopRightArea else { return }   // no notch
        let notchMinX = screen.frame.minX + left.maxX
        var notchMaxX = screen.frame.minX + right.minX
        // Test hook: pretend the notch reaches this x to exercise the shrink path.
        if let fake = ProcessInfo.processInfo.environment["RM_DEBUG_NOTCH_MAX_X"].flatMap(Double.init) {
            notchMaxX = fake
        }
        let f = window.frame
        if f.minX < notchMaxX && f.maxX > notchMinX {
            NSLog("status item %@ overlaps notch (%.0f-%.0f); showing fewer metrics",
                  NSStringFromRect(f), notchMinX, notchMaxX)
            monitor.shrinkForSpace()
        } else if ProcessInfo.processInfo.environment["RM_DEBUG"] != nil {
            NSLog("status item %@ fits", NSStringFromRect(f))
        }
    }

    @objc private func togglePanel(_ sender: Any?) {
        guard let button = statusItem.button else { return }
        panel.toggle(from: button)
    }
}

/// `Glance --dump` prints one sample of every collector (for testing without UI).
enum Dump {
    static func run() {
        let cpu = CPUSampler(), disk = DiskSampler(), net = NetworkSampler()
        _ = cpu.sample(); _ = disk.sample(); _ = net.sample()
        Thread.sleep(forTimeInterval: 1.0)
        let c = cpu.sample() ?? CPUStats()
        let m = MemorySampler.sample()
        let d = disk.sample(blockingVolumeScan: true)
        let n = net.sample()
        let b = BluetoothSampler.sample() ?? BluetoothStats()
        let bat = BatterySampler.sample()
        let t = TemperatureSampler().sample()

        print("== CPU ==")
        print("total \(Fmt.percent(c.total))  user \(Fmt.percent(c.user))  sys \(Fmt.percent(c.system))  cores \(c.perCore.count)")
        print("per-core: " + c.perCore.map { Fmt.percent($0) }.joined(separator: " "))
        print("== Memory ==")
        print("used \(Fmt.bytes(m.used, base: 1024)) / \(Fmt.bytes(m.total, base: 1024)) (\(Fmt.percent(m.usedFraction)))")
        print("app \(Fmt.bytes(m.app, base: 1024))  wired \(Fmt.bytes(m.wired, base: 1024))  compressed \(Fmt.bytes(m.compressed, base: 1024))  cached \(Fmt.bytes(m.cached, base: 1024))")
        print("swap \(Fmt.bytes(m.swapUsed, base: 1024)) / \(Fmt.bytes(m.swapTotal, base: 1024))  pressure level \(m.pressureLevel)")
        print("== Disk ==")
        for v in d.volumes {
            print("\(v.isRoot ? "*" : " ") \(v.name) [\(v.path)] used \(Fmt.bytes(v.used)) / \(Fmt.bytes(v.total)) (\(Fmt.percent(v.usedFraction))) free \(Fmt.bytes(v.available))")
        }
        print("read \(Fmt.rate(d.readRate))  write \(Fmt.rate(d.writeRate))")
        print("== Network ==")
        print("total ↓ \(Fmt.rate(n.rxRate))  ↑ \(Fmt.rate(n.txRate))")
        for i in n.interfaces {
            print("\(i.bsdName) \(i.displayName) [\(i.kind.rawValue)] active=\(i.isActive) ipv4=\(i.ipv4) link=\(Fmt.linkSpeed(i.linkSpeed)) ↓ \(Fmt.rate(i.rxRate)) ↑ \(Fmt.rate(i.txRate)) total ↓ \(Fmt.bytes(i.rxTotal)) ↑ \(Fmt.bytes(i.txTotal))")
        }
        if let w = n.wifi {
            print("wifi \(w.interfaceName) power=\(w.powerOn) ssid=\(w.ssid ?? "nil(위치 권한 필요)") rssi=\(w.rssi) noise=\(w.noise) tx=\(w.txRate)Mbps ch=\(w.channel.map(String.init) ?? "-") \(w.band ?? "") \(w.phyMode ?? "")")
        }
        print("== Temperature ==")
        print("available=\(t.available) cpu avg \(String(format: "%.1f", t.cpuAverage))°C max \(String(format: "%.1f", t.cpuMax))°C ssd \(t.ssd.map { String(format: "%.1f", $0) } ?? "-") battery \(t.battery.map { String(format: "%.1f", $0) } ?? "-")")
        print("== Battery ==")
        print("present=\(bat.present) \(bat.percent)% charging=\(bat.isCharging) charged=\(bat.isCharged) ac=\(bat.onAC) toEmpty=\(bat.timeToEmpty.map(String.init) ?? "-")m toFull=\(bat.timeToFull.map(String.init) ?? "-")m")
        print("cycles=\(bat.cycleCount ?? -1) health=\(bat.health.map { Fmt.percent($0) } ?? "-") temp=\(bat.temperature.map { String(format: "%.1f", $0) } ?? "-")°C watts=\(bat.watts.map { String(format: "%.2f", $0) } ?? "-") adapter=\(bat.adapterWatts ?? 0)W \(bat.adapterName ?? "")")
        print("== Bluetooth ==")
        print("available=\(b.available) power=\(b.poweredOn) connected=\(b.connected.count) paired(not connected)=\(b.paired.count)")
        for dev in b.connected + b.paired {
            print("\(dev.connected ? "●" : "○") \(dev.name) [\(dev.minorType)] " + dev.batteries.map { "\($0.label) \($0.percent)%" }.joined(separator: " "))
        }
    }
}

/// `Glance --snapshot <dir>` renders the menu bar label and popover to PNGs (UI check without screen recording).
@MainActor
enum Snapshotter {
    static func run(outDir: String) {
        _ = NSApplication.shared
        let monitor = ResourceMonitor()
        monitor.persistsSettings = false
        monitor.start()
        RunLoop.main.run(until: Date().addingTimeInterval(4.5))
        func save(_ view: some View, _ name: String, dark: Bool) {
            let renderer = ImageRenderer(content: view
                .environment(\.colorScheme, dark ? .dark : .light)
                .background(dark ? Color(white: 0.16) : Color(white: 0.96)))
            renderer.scale = 2
            guard let cg = renderer.cgImage else { print("render failed: \(name)"); return }
            let rep = NSBitmapImageRep(cgImage: cg)
            let url = URL(fileURLWithPath: outDir).appendingPathComponent(name)
            try? rep.representation(using: .png, properties: [:])?.write(to: url)
            print("wrote \(url.path)")
        }
        func panel(_ dark: Bool) -> some View {
            PanelRoot().environmentObject(monitor)
        }
        save(StatusBarLabel(style: .detailed, metrics: StatusMetric.allCases, snapshot: monitor.snapshot), "menubar-detailed.png", dark: false)
        save(StatusBarLabel(style: .compact, metrics: StatusMetric.allCases, snapshot: monitor.snapshot), "menubar-compact.png", dark: false)
        save(StatusBarLabel(style: .icon, metrics: [], snapshot: monitor.snapshot), "menubar-icon.png", dark: false)
        monitor.page = nil
        save(panel(false), "panel-home.png", dark: false)
        save(panel(true), "panel-home-dark.png", dark: true)
        for section in DetailSection.allCases {
            monitor.page = section
            save(panel(false), "panel-\(section.rawValue).png", dark: false)
        }
        monitor.page = nil
        save(SettingsForm().environmentObject(monitor), "settings.png", dark: false)
        let levels = [5, 20, 50, 85, 100]
        save(VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 12) {
                ForEach(levels, id: \.self) { p in
                    BatteryGlyph(level: Double(p) / 100, text: "\(p)",
                                 power: p == 50 ? .charging : (p == 100 ? .pluggedIn : .battery),
                                 color: .black, bodySize: CGSize(width: 27, height: 13))
                }
            }
            HStack(spacing: 12) {
                ForEach(levels, id: \.self) { p in
                    BatteryGlyph(level: Double(p) / 100, text: "\(p)",
                                 power: p == 50 ? .charging : (p == 100 ? .pluggedIn : .battery),
                                 color: p <= 20 ? .red : (p == 50 ? .green : .accentColor),
                                 bodySize: CGSize(width: 38, height: 19))
                }
            }
        }.padding(10), "battery-glyphs.png", dark: false)
    }
}
