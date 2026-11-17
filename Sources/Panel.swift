import AppKit
import SwiftUI
import Combine

// MARK: - Design tokens

/// Control Center–style tokens. Radii are concentric: module = panel − padding.
enum Theme {
    static let accent = Color.accentColor
    static let panelWidth: CGFloat = 320
    static let panelPadding: CGFloat = 10
    static let panelRadius: CGFloat = 24
    static let moduleRadius: CGFloat = panelRadius - panelPadding   // 14
    static let moduleSpacing: CGFloat = 8
    static let cardFill = Color.primary.opacity(0.045)
    static let moduleFill = Color.primary.opacity(0.07)
    static let moduleHover = Color.primary.opacity(0.12)
    static let track = Color.primary.opacity(0.1)

    /// Accent normally, orange/red only past warning thresholds.
    static func usage(_ fraction: Double) -> Color {
        switch fraction {
        case ..<0.75: return accent
        case ..<0.9: return .orange
        default: return .red
        }
    }

    static func temperature(_ c: Double) -> Color {
        switch c {
        case ..<75: return accent
        case ..<90: return .orange
        default: return .red
        }
    }
}

enum DetailSection: String, CaseIterable, Identifiable {
    case cpu, memory, network, disk, temperature, battery, bluetooth
    var id: String { rawValue }
    var title: String {
        switch self {
        case .cpu: return "CPU"
        case .memory: return "메모리"
        case .disk: return "디스크"
        case .network: return "네트워크"
        case .temperature: return "온도"
        case .battery: return "배터리"
        case .bluetooth: return "블루투스"
        }
    }
    var symbol: String {
        switch self {
        case .cpu: return "cpu"
        case .memory: return "memorychip"
        case .disk: return "internaldrive"
        case .network: return "network"
        case .temperature: return "thermometer.medium"
        case .battery: return "battery.100percent"
        case .bluetooth: return "dot.radiowaves.left.and.right"
        }
    }
}

struct Banner: View {
    let text: String
    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
            Text(text).foregroundStyle(.secondary)
        }
        .font(.system(size: 11))
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(Color.orange.opacity(0.12)))
    }
}

// MARK: - Panel root

/// Content of the menu bar panel: module grid, or one detail page (Control Center–style drill-in).
struct PanelRoot: View {
    @EnvironmentObject private var m: ResourceMonitor
    /// true inside the window (pin content to the top); false when measuring the natural height.
    var fillHeight = true

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.moduleSpacing) {
            if let page = m.visiblePage {
                DetailPage(section: page)
            } else {
                HomePage()
            }
        }
        .padding(Theme.panelPadding)
        .frame(width: Theme.panelWidth)
        .fixedSize(horizontal: false, vertical: true)
        .frame(maxHeight: fillHeight ? .infinity : nil, alignment: .top)
    }
}

// MARK: Home (module grid)

struct HomePage: View {
    @EnvironmentObject private var m: ResourceMonitor

    var body: some View {
        let s = m.snapshot
        if !m.hiddenForSpace.isEmpty {
            Banner(text: "메뉴바 공간이 부족해 \(m.hiddenForSpace.map(\.shortTitle).joined(separator: ", ")) 표시를 숨겼어요")
        }

        HStack(spacing: Theme.moduleSpacing) {
            UsageModule(section: .cpu, value: s.cpu.total,
                        subtitle: "\(s.cpu.perCore.count)코어")
            UsageModule(section: .memory, value: s.memory.usedFraction,
                        subtitle: "\(Fmt.bytes(s.memory.used, base: 1024)) 사용")
        }

        NetworkModule()

        let small = m.visibleSections.filter { [.disk, .temperature, .battery, .bluetooth].contains($0) }
        HStack(spacing: Theme.moduleSpacing) {
            ForEach(small) { SmallModule(section: $0) }
        }

        VStack(spacing: 0) {
            MenuRow(id: "activity", title: "활성 상태 보기 열기…") { m.actions.openActivityMonitor(); m.actions.close() }
            MenuRow(id: "settings", title: "Glance 설정…") { m.actions.openSettings() }
            MenuRow(id: "quit", title: "Glance 종료") { m.actions.quit() }
        }
        .padding(.top, 2)
    }
}

/// Circular icon badge, like Control Center toggles. Filled with the state color.
struct Badge: View {
    let symbol: String
    var color: Color = Theme.accent
    var size: CGFloat = 28

    var body: some View {
        ZStack {
            Circle().fill(color)
            Image(systemName: symbol)
                .font(.system(size: size * 0.45, weight: .semibold))
                .foregroundStyle(.white)
        }
        .frame(width: size, height: size)
    }
}

/// Rounded platter that highlights on hover and opens a detail page on click.
struct ModuleButton<Content: View>: View {
    @EnvironmentObject private var m: ResourceMonitor
    let section: DetailSection
    @ViewBuilder var content: Content

    var body: some View {
        Button {
            m.hovered = nil
            m.page = section
        } label: {
            content
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(
                    RoundedRectangle(cornerRadius: Theme.moduleRadius, style: .continuous)
                        .fill(m.hovered == section.rawValue ? Theme.moduleHover : Theme.moduleFill)
                )
                .contentShape(RoundedRectangle(cornerRadius: Theme.moduleRadius, style: .continuous))
        }
        .buttonStyle(PressScaleStyle())
        .onHover { inside in
            if inside { m.hovered = section.rawValue } else if m.hovered == section.rawValue { m.hovered = nil }
        }
    }
}

struct PressScaleStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed ? 0.97 : 1)
            .animation(.easeOut(duration: 0.12), value: configuration.isPressed)
    }
}

/// Large module: badge + title/subtitle, with a slider-like usage bar (Display/Sound module look).
struct UsageModule: View {
    let section: DetailSection
    let value: Double
    let subtitle: String

    var body: some View {
        ModuleButton(section: section) {
            VStack(alignment: .leading, spacing: 10) {
                HStack(spacing: 8) {
                    Badge(symbol: section.symbol, color: Theme.usage(value))
                    VStack(alignment: .leading, spacing: 0) {
                        Text(section.title).font(.system(size: 13, weight: .semibold))
                        Text(subtitle).font(.system(size: 11)).foregroundStyle(.secondary).lineLimit(1)
                    }
                    Spacer(minLength: 0)
                }
                HStack(spacing: 6) {
                    UsageBar(value, color: Theme.usage(value), height: 5)
                    Text(Fmt.percent(value))
                        .font(.system(size: 12, weight: .semibold).monospacedDigit())
                        .frame(width: 34, alignment: .trailing)
                }
            }
            .padding(12)
        }
    }
}

/// Wide network module: connection badge, name, live rates, chevron.
struct NetworkModule: View {
    @EnvironmentObject private var m: ResourceMonitor

    var body: some View {
        let n = m.snapshot.network
        let wifi = n.wifi
        let name: String = {
            if n.primaryKind == .wifi, let ssid = wifi?.ssid { return ssid }
            return n.connectionName
        }()
        let detail: String = {
            let active = n.interfaces.first { $0.isActive && $0.kind == n.primaryKind }
            return active?.ipv4.first ?? (n.primaryKind == nil ? "오프라인" : n.connectionName)
        }()
        ModuleButton(section: .network) {
            HStack(spacing: 8) {
                Badge(symbol: n.connectionSymbol, color: n.primaryKind == nil ? Color.secondary : Theme.accent)
                VStack(alignment: .leading, spacing: 0) {
                    Text(name).font(.system(size: 13, weight: .semibold)).lineLimit(1)
                    Text(detail).font(.system(size: 11)).foregroundStyle(.secondary).lineLimit(1)
                }
                Spacer(minLength: 4)
                VStack(alignment: .trailing, spacing: 1) {
                    Text("↓ " + Fmt.rate(n.rxRate))
                    Text("↑ " + Fmt.rate(n.txRate)).foregroundStyle(.secondary)
                }
                .font(.system(size: 11, weight: .medium).monospacedDigit())
                Image(systemName: "chevron.right")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(.tertiary)
            }
            .padding(12)
        }
    }
}

/// Small square module: badge (or battery glyph), value, title.
struct SmallModule: View {
    @EnvironmentObject private var m: ResourceMonitor
    let section: DetailSection

    var body: some View {
        let s = m.snapshot
        ModuleButton(section: section) {
            VStack(spacing: 5) {
                Group {
                    switch section {
                    case .battery:
                        let b = s.battery
                        BatteryGlyph(level: Double(b.percent) / 100, text: "\(b.percent)", power: b.powerState,
                                     color: b.percent <= 20 && !b.onAC ? .red : (b.isCharging ? .green : Theme.accent),
                                     bodySize: CGSize(width: 30, height: 15))
                    case .disk:
                        Badge(symbol: section.symbol, color: Theme.usage(s.disk.root?.usedFraction ?? 0))
                    case .temperature:
                        Badge(symbol: section.symbol, color: Theme.temperature(s.temperature.cpuAverage))
                    case .bluetooth:
                        Badge(symbol: section.symbol, color: s.bluetooth.poweredOn ? Theme.accent : Color.secondary)
                    default:
                        Badge(symbol: section.symbol)
                    }
                }
                .frame(height: 28)
                Text(value(s))
                    .font(.system(size: 12, weight: .semibold).monospacedDigit())
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)
                Text(section.title)
                    .font(.system(size: 10.5))
                    .foregroundStyle(.secondary)
            }
            .padding(.vertical, 10)
            .frame(maxWidth: .infinity)
        }
    }

    private func value(_ s: Snapshot) -> String {
        switch section {
        case .disk: return Fmt.percent(s.disk.root?.usedFraction ?? 0)
        case .temperature: return Fmt.temp(s.temperature.cpuAverage)
        case .battery:
            switch s.battery.powerState {
            case .charging: return "충전 중"
            case .pluggedIn: return "전원 연결"
            case .battery: return "\(s.battery.percent)%"
            }
        case .bluetooth:
            let bt = s.bluetooth
            return !bt.available ? "…" : (bt.poweredOn ? "\(bt.connected.count)대 연결" : "끔")
        default: return ""
        }
    }
}

/// Menu-style row with hover highlight (bottom of the panel).
struct MenuRow: View {
    @EnvironmentObject private var m: ResourceMonitor
    let id: String
    let title: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Text(title)
                .font(.system(size: 13))
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 10)
                .padding(.vertical, 5)
                .background(
                    RoundedRectangle(cornerRadius: 7, style: .continuous)
                        .fill(m.hovered == id ? Theme.moduleHover : .clear)
                )
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { inside in
            if inside { m.hovered = id } else if m.hovered == id { m.hovered = nil }
        }
    }
}

// MARK: Detail page

struct DetailPage: View {
    @EnvironmentObject private var m: ResourceMonitor
    let section: DetailSection

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 6) {
                Button {
                    m.hovered = nil
                    m.page = nil
                } label: {
                    HStack(spacing: 4) {
                        Image(systemName: "chevron.left").font(.system(size: 12, weight: .semibold))
                        Text(section.title).font(.system(size: 15, weight: .semibold))
                    }
                    .padding(.horizontal, 6)
                    .padding(.vertical, 3)
                    .background(
                        RoundedRectangle(cornerRadius: 7, style: .continuous)
                            .fill(m.hovered == "back" ? Theme.moduleHover : .clear)
                    )
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .onHover { inside in
                    if inside { m.hovered = "back" } else if m.hovered == "back" { m.hovered = nil }
                }
                .help("뒤로 (Esc)")
                Spacer()
            }
            .padding(.leading, -4)

            VStack(alignment: .leading, spacing: 10) {
                switch section {
                case .cpu: CPUDetail()
                case .memory: MemoryDetail()
                case .disk: DiskDetail()
                case .network: NetworkDetail()
                case .temperature: TemperatureDetail()
                case .battery: BatteryDetail()
                case .bluetooth: BluetoothDetail()
                }
            }
            .padding(.horizontal, 4)

            Divider().padding(.vertical, 2)
            MenuRow(id: "activity", title: "활성 상태 보기 열기…") { m.actions.openActivityMonitor(); m.actions.close() }
        }
    }
}

// MARK: - Panel window

/// Borderless panel that can take key focus (for Esc) without a title bar.
final class GlancePanel: NSPanel {
    override var canBecomeKey: Bool { true }
}

/// Shows the panel right under the status item (no arrow), Liquid Glass background on macOS 26,
/// closes on outside click / Esc / app switch, and resizes with its top edge pinned.
@MainActor
final class PanelController: NSObject, NSWindowDelegate {
    private let monitor: ResourceMonitor
    private let panel: GlancePanel
    private var hosting: NSView!
    /// Off-screen copy of the content used to measure its natural height.
    private var measurer: NSHostingController<AnyView>!
    private var changeSubscription: AnyCancellable?
    private var anchor: NSRect = .zero
    private var globalClickMonitor: Any?
    private var keyMonitor: Any?
    private var lastClose = Date.distantPast

    var isShown: Bool { panel.isVisible }

    init(monitor: ResourceMonitor) {
        self.monitor = monitor
        panel = GlancePanel(contentRect: NSRect(x: 0, y: 0, width: Theme.panelWidth, height: 400),
                            styleMask: [.borderless, .nonactivatingPanel],
                            backing: .buffered, defer: true)
        super.init()
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.level = .popUpMenu
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient]
        panel.isMovable = false
        panel.hidesOnDeactivate = false
        panel.isReleasedWhenClosed = false
        panel.delegate = self

        let hosting = NSHostingView(rootView: AnyView(PanelRoot().environmentObject(monitor)))
        measurer = NSHostingController(rootView: AnyView(PanelRoot(fillHeight: false).environmentObject(monitor)))
        hosting.sizingOptions = []
        hosting.frame = NSRect(x: 0, y: 0, width: Theme.panelWidth, height: 400)
        hosting.autoresizingMask = [.width, .height]
        self.hosting = hosting

        if #available(macOS 26.0, *) {
            let glass = NSGlassEffectView(frame: hosting.frame)
            glass.cornerRadius = Theme.panelRadius
            glass.contentView = hosting
            panel.contentView = glass
        } else {
            let fx = NSVisualEffectView()
            fx.material = .popover
            fx.blendingMode = .behindWindow
            fx.state = .active
            fx.wantsLayer = true
            fx.layer?.cornerRadius = Theme.panelRadius
            fx.layer?.cornerCurve = .continuous
            fx.layer?.masksToBounds = true
            fx.frame = hosting.frame
            fx.addSubview(hosting)
            panel.contentView = fx
        }
    }

    /// Toggle from the status item. A click that just closed the panel (outside-click handler
    /// fires first) must not immediately reopen it.
    func toggle(from button: NSStatusBarButton) {
        if panel.isVisible {
            close()
        } else if Date().timeIntervalSince(lastClose) > 0.25 {
            show(from: button)
        }
    }

    func show(from button: NSStatusBarButton) {
        guard let window = button.window else { return }
        anchor = window.convertToScreen(button.convert(button.bounds, to: nil))
        monitor.page = nil
        monitor.hovered = nil
        place(size: NSSize(width: Theme.panelWidth, height: contentHeight()))
        // Non-activating panel: takes key focus (Esc) without activating the app, like Control Center.
        panel.makeKeyAndOrderFront(nil)
        // Content changes (new data, page switch) → re-measure after SwiftUI applies them.
        changeSubscription = monitor.objectWillChange.sink { [weak self] _ in
            DispatchQueue.main.async { self?.refit() }
        }
        debugLog("show frame=\(NSStringFromRect(panel.frame)) key=\(panel.isKeyWindow) active=\(NSApp.isActive)")

        globalClickMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak self] _ in
            MainActor.assumeIsolated { self?.close(reason: "outside click") }
        }
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard event.keyCode == 53 else { return event }   // Esc
            MainActor.assumeIsolated {
                guard let self else { return }
                if self.monitor.page != nil { self.monitor.page = nil } else { self.close() }
            }
            return nil
        }
    }

    func close(reason: String = "") {
        guard panel.isVisible else { return }
        debugLog("close \(reason)")
        panel.orderOut(nil)
        lastClose = Date()
        monitor.hovered = nil
        if let g = globalClickMonitor { NSEvent.removeMonitor(g) }
        if let k = keyMonitor { NSEvent.removeMonitor(k) }
        globalClickMonitor = nil
        keyMonitor = nil
        changeSubscription = nil
    }

    nonisolated func windowDidResignKey(_ notification: Notification) {
        MainActor.assumeIsolated {
            let front = NSWorkspace.shared.frontmostApplication?.localizedName ?? "?"
            close(reason: "resign key (frontmost=\(front), key=\(String(describing: NSApp.keyWindow)))")
        }
    }

    private func debugLog(_ msg: String) {
        if ProcessInfo.processInfo.environment["RM_DEBUG"] != nil { NSLog("panel: %@", msg) }
    }

    private func contentHeight() -> CGFloat {
        let h = measurer.sizeThatFits(in: CGSize(width: Theme.panelWidth, height: 5000)).height
        return h > 0 && h < 5000 ? ceil(h) : 400
    }

    private func refit() {
        guard panel.isVisible else { return }
        let h = contentHeight()
        guard abs(h - panel.frame.height) > 0.5 else { return }
        debugLog("resize \(h)")
        place(size: NSSize(width: Theme.panelWidth, height: h))
    }

    /// Below the menu bar, left edge aligned with the status item, kept on screen.
    private func place(size: NSSize) {
        let screen = NSScreen.screens.first { $0.frame.contains(NSPoint(x: anchor.midX, y: anchor.midY)) }
            ?? NSScreen.main
        guard let visible = screen?.visibleFrame else { return }
        var x = anchor.minX
        x = min(x, visible.maxX - size.width - 6)
        x = max(x, visible.minX + 6)
        let top = anchor == .zero ? visible.maxY : anchor.minY - 6
        panel.setFrame(NSRect(x: x, y: top - size.height, width: size.width, height: size.height),
                       display: true)
    }
}
