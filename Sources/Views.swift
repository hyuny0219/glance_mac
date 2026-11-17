import SwiftUI
import CoreLocation

// MARK: - Menu bar label (rendered to a template image)

struct StatusBarLabel: View {
    var style: MenuBarStyle = .detailed
    let metrics: [StatusMetric]
    let snapshot: Snapshot

    var body: some View {
        Group {
            switch style {
            case .icon:
                Image(systemName: "gauge.with.dots.needle.50percent")
                    .font(.system(size: 14, weight: .medium))
            case .compact:
                compact
            case .detailed:
                detailed
            }
        }
        .foregroundStyle(.black)
        .padding(.horizontal, 1)
        .frame(height: 22)
        .fixedSize()
    }

    // One line per metric: SF Symbol + value (Apple menu-extra style, e.g. "􀧓 11%").
    private var compact: some View {
        HStack(spacing: 9) {
            ForEach(metrics) { metric in
                switch metric {
                case .battery:
                    if snapshot.battery.present { batteryGlyph }
                case .network:
                    HStack(spacing: 3) {
                        Image(systemName: snapshot.network.connectionSymbol)
                        Text("↓" + Fmt.compactRate(snapshot.network.rxRate))
                    }
                default:
                    HStack(spacing: 3) {
                        Image(systemName: metric.symbol)
                        Text(compactValue(metric))
                    }
                }
            }
        }
        .font(.system(size: 12, weight: .medium).monospacedDigit())
    }

    private func compactValue(_ metric: StatusMetric) -> String {
        switch metric {
        case .cpu: return Fmt.percent(snapshot.cpu.total)
        case .memory: return Fmt.percent(snapshot.memory.usedFraction)
        case .disk: return Fmt.percent(snapshot.disk.root?.usedFraction ?? 0)
        case .temperature: return snapshot.temperature.available ? Fmt.temp(snapshot.temperature.cpuAverage) : "-"
        case .bluetooth:
            return !snapshot.bluetooth.available ? "…" : (snapshot.bluetooth.poweredOn ? "\(snapshot.bluetooth.connected.count)" : "off")
        case .battery, .network: return ""
        }
    }

    private var batteryGlyph: some View {
        BatteryGlyph(level: Double(snapshot.battery.percent) / 100,
                     text: "\(snapshot.battery.percent)",
                     power: snapshot.battery.powerState,
                     color: .black, bodySize: CGSize(width: 27, height: 13))
    }

    // Two-line caption/value blocks (dense, iStat-like).
    private var detailed: some View {
        HStack(spacing: 5) {
            ForEach(metrics) { metric in
                switch metric {
                case .cpu:
                    block("CPU", Fmt.percent(snapshot.cpu.total))
                case .temperature:
                    block("TEMP", snapshot.temperature.available ? Fmt.temp(snapshot.temperature.cpuAverage) : "-")
                case .battery:
                    if snapshot.battery.present { batteryGlyph }
                case .memory:
                    block("MEM", Fmt.percent(snapshot.memory.usedFraction))
                case .disk:
                    block("SSD", Fmt.percent(snapshot.disk.root?.usedFraction ?? 0))
                case .network:
                    Image(systemName: snapshot.network.connectionSymbol)
                        .font(.system(size: 11, weight: .semibold))
                        .padding(.trailing, -3)
                    VStack(alignment: .trailing, spacing: -1) {
                        Text("↑ " + Fmt.compactRate(snapshot.network.txRate))
                        Text("↓ " + Fmt.compactRate(snapshot.network.rxRate))
                    }
                    .font(.system(size: 9, weight: .semibold).monospacedDigit())
                    .frame(width: 37, alignment: .trailing)
                case .bluetooth:
                    block("BT", compactValue(.bluetooth))
                }
            }
        }
    }

    private func block(_ title: String, _ value: String) -> some View {
        VStack(spacing: -1) {
            Text(title).font(.system(size: 7.5, weight: .medium))
            Text(value).font(.system(size: 10, weight: .semibold).monospacedDigit())
        }
        .frame(minWidth: 24)
    }
}

/// Battery outline with a translucent fill to `level` and the number drawn solid on top,
/// so it stays readable at any level and in monochrome template images.
struct BatteryGlyph: View {
    let level: Double
    let text: String
    let power: PowerState
    let color: Color
    let bodySize: CGSize

    var body: some View {
        let h = bodySize.height
        let radius = h * 0.3
        let inset = max(1.5, h * 0.12)
        HStack(spacing: 1) {
            if power != .battery {
                Image(systemName: power == .charging ? "bolt.fill" : "powerplug.fill")
                    .font(.system(size: h * 0.62, weight: .bold))
                    .foregroundStyle(color)
            }
            HStack(spacing: h * 0.06) {
                ZStack(alignment: .leading) {
                    RoundedRectangle(cornerRadius: radius, style: .continuous)
                        .strokeBorder(color.opacity(0.45), lineWidth: max(1, h * 0.08))
                    let fillW = max(0, (bodySize.width - inset * 2) * CGFloat(min(1, max(0, level))))
                    ZStack {
                        RoundedRectangle(cornerRadius: max(1, radius - inset * 0.6), style: .continuous)
                            .fill(color.opacity(0.32))
                            .frame(width: fillW)
                            .frame(maxWidth: .infinity, alignment: .leading)
                        Text(text)
                            .font(.system(size: h * 0.68, weight: .bold, design: .rounded).monospacedDigit())
                            .foregroundStyle(color)
                            .lineLimit(1)
                            .minimumScaleFactor(0.6)
                    }
                    .padding(inset)
                }
                .frame(width: bodySize.width, height: h)
                RoundedRectangle(cornerRadius: h * 0.08)
                    .fill(color.opacity(0.45))
                    .frame(width: max(1.5, h * 0.11), height: h * 0.36)
            }
        }
        .fixedSize()
    }
}

// MARK: - Detail page components

/// Headline of a detail page: caption on the left, the big number on the right.
struct DetailHeader: View {
    let title: String          // shown in the page header; kept for call-site clarity
    let value: String
    var caption: String? = nil
    var symbol: String? = nil
    var symbolActive = true

    var body: some View {
        HStack(alignment: .lastTextBaseline) {
            HStack(spacing: 5) {
                if let symbol {
                    Image(systemName: symbol)
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(symbolActive ? Theme.accent : Color.secondary)
                }
                if let caption {
                    Text(caption).font(.system(size: 12)).foregroundStyle(.secondary).lineLimit(1)
                }
            }
            Spacer()
            Text(value)
                .font(.system(size: 22, weight: .semibold, design: .rounded).monospacedDigit())
                .lineLimit(1)
                .minimumScaleFactor(0.7)
        }
    }
}

struct StatRow: View {
    let label: String
    let value: String
    var dot: Color? = nil

    var body: some View {
        HStack(spacing: 6) {
            if let dot { Circle().fill(dot).frame(width: 6, height: 6) }
            Text(label).foregroundStyle(.secondary)
            Spacer(minLength: 8)
            Text(value).monospacedDigit().lineLimit(1)
        }
        .font(.system(size: 12))
    }
}

struct LegendItem: View {
    let label: String
    let color: Color
    var body: some View {
        HStack(spacing: 4) {
            Capsule().fill(color).frame(width: 10, height: 3)
            Text(label).foregroundStyle(.secondary)
        }
        .font(.system(size: 10.5))
    }
}

struct SubHeading: View {
    let text: String
    var body: some View {
        Text(text)
            .font(.system(size: 11, weight: .semibold))
            .foregroundStyle(.secondary)
            .padding(.top, 4)
    }
}

struct UsageBar: View {
    var segments: [(Double, Color)]
    var height: CGFloat = 6

    init(_ value: Double, color: Color, height: CGFloat = 6) {
        segments = [(value, color)]
        self.height = height
    }

    init(segments: [(Double, Color)], height: CGFloat = 6) {
        self.segments = segments
        self.height = height
    }

    var body: some View {
        GeometryReader { geo in
            ZStack(alignment: .leading) {
                Capsule().fill(Theme.track)
                HStack(spacing: 0) {
                    ForEach(Array(segments.enumerated()), id: \.offset) { _, seg in
                        Rectangle().fill(seg.1)
                            .frame(width: geo.size.width * CGFloat(max(0, min(1, seg.0))))
                    }
                }
                .clipShape(Capsule())
            }
        }
        .frame(height: height)
    }
}

struct Sparkline: View {
    var values: [Double]
    var maxValue: Double? = nil
    var minValue: Double = 0
    var color: Color
    var capacity = 60
    var filled = true

    var body: some View {
        GeometryReader { geo in
            let mx = max(maxValue ?? (values.max() ?? 0), minValue + 1e-9)
            let w = geo.size.width, h = geo.size.height
            let step = w / CGFloat(max(capacity - 1, 1))
            let startX = w - step * CGFloat(max(values.count - 1, 0))
            let points = values.enumerated().map { i, v in
                CGPoint(x: startX + CGFloat(i) * step,
                        y: h - h * CGFloat(min(max((v - minValue) / (mx - minValue), 0), 1)))
            }
            ZStack {
                if points.count > 1 {
                    if filled {
                        Path { p in
                            p.move(to: CGPoint(x: points[0].x, y: h))
                            points.forEach { p.addLine(to: $0) }
                            p.addLine(to: CGPoint(x: points.last!.x, y: h))
                            p.closeSubpath()
                        }
                        .fill(LinearGradient(colors: [color.opacity(0.28), color.opacity(0.02)],
                                             startPoint: .top, endPoint: .bottom))
                    }
                    Path { p in
                        p.move(to: points[0])
                        points.dropFirst().forEach { p.addLine(to: $0) }
                    }
                    .stroke(color, style: StrokeStyle(lineWidth: 1.5, lineCap: .round, lineJoin: .round))
                }
            }
        }
    }
}

struct ChartBox<Content: View>: View {
    var height: CGFloat = 48
    @ViewBuilder var content: Content
    var body: some View {
        content
            .frame(height: height)
            .padding(.vertical, 4)
            .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(Color.primary.opacity(0.035)))
    }
}

// MARK: CPU

struct CPUDetail: View {
    @EnvironmentObject private var m: ResourceMonitor

    var body: some View {
        let c = m.snapshot.cpu
        DetailHeader(title: "CPU", value: Fmt.percent(c.total), caption: "\(c.perCore.count)코어")
        ChartBox { Sparkline(values: m.cpuHistory, maxValue: 1, color: Theme.usage(c.total)) }
        HStack(spacing: 16) {
            StatRow(label: "사용자", value: Fmt.percent(c.user), dot: Theme.accent)
            StatRow(label: "시스템", value: Fmt.percent(c.system), dot: Theme.accent.opacity(0.45))
        }
        if !c.perCore.isEmpty {
            SubHeading(text: "코어별")
            HStack(alignment: .bottom, spacing: 3) {
                ForEach(Array(c.perCore.enumerated()), id: \.offset) { _, v in
                    GeometryReader { geo in
                        ZStack(alignment: .bottom) {
                            RoundedRectangle(cornerRadius: 2).fill(Theme.track)
                            RoundedRectangle(cornerRadius: 2)
                                .fill(Theme.usage(v))
                                .frame(height: max(2, geo.size.height * CGFloat(v)))
                        }
                    }
                }
            }
            .frame(height: 24)
        }
    }
}

// MARK: Memory

struct MemoryDetail: View {
    @EnvironmentObject private var m: ResourceMonitor

    var body: some View {
        let mem = m.snapshot.memory
        let total = Double(max(mem.total, 1))
        DetailHeader(title: "메모리", value: Fmt.percent(mem.usedFraction),
                     caption: "\(Fmt.bytes(mem.used, base: 1024)) / \(Fmt.bytes(mem.total, base: 1024)) 사용")
        UsageBar(segments: [
            (Double(mem.app) / total, Theme.accent),
            (Double(mem.wired) / total, Theme.accent.opacity(0.6)),
            (Double(mem.compressed) / total, Theme.accent.opacity(0.32)),
        ], height: 8)
        VStack(spacing: 5) {
            StatRow(label: "앱 메모리", value: Fmt.bytes(mem.app, base: 1024), dot: Theme.accent)
            StatRow(label: "와이어드", value: Fmt.bytes(mem.wired, base: 1024), dot: Theme.accent.opacity(0.6))
            StatRow(label: "압축됨", value: Fmt.bytes(mem.compressed, base: 1024), dot: Theme.accent.opacity(0.32))
        }
        Divider()
        VStack(spacing: 5) {
            HStack {
                Text("메모리 압력").foregroundStyle(.secondary)
                Spacer()
                PressurePill(level: mem.pressureLevel)
            }
            .font(.system(size: 11.5))
            StatRow(label: "스왑 사용", value: Fmt.bytes(mem.swapUsed, base: 1024))
            StatRow(label: "캐시된 파일", value: Fmt.bytes(mem.cached, base: 1024))
        }
    }
}

struct PressurePill: View {
    let level: Int
    var body: some View {
        let (text, color): (String, Color) = {
            switch level {
            case 4: return ("위험", .red)
            case 2: return ("경고", .orange)
            default: return ("정상", .green)
            }
        }()
        Text(text)
            .font(.system(size: 10.5, weight: .semibold))
            .foregroundStyle(color)
            .padding(.horizontal, 7)
            .padding(.vertical, 2)
            .background(Capsule().fill(color.opacity(0.13)))
    }
}

// MARK: Disk

struct DiskDetail: View {
    @EnvironmentObject private var m: ResourceMonitor

    var body: some View {
        let d = m.snapshot.disk
        let root = d.root
        DetailHeader(title: "디스크", value: Fmt.percent(root?.usedFraction ?? 0),
                     caption: root.map { "\(Fmt.bytes($0.available)) 사용 가능" })
        ForEach(d.volumes) { v in
            VStack(alignment: .leading, spacing: 5) {
                HStack(spacing: 6) {
                    Image(systemName: v.isRoot ? "internaldrive" : "externaldrive")
                        .foregroundStyle(.secondary)
                    Text(v.name).lineLimit(1)
                    Spacer()
                    Text("\(Fmt.bytes(v.used)) / \(Fmt.bytes(v.total))")
                        .foregroundStyle(.secondary).monospacedDigit()
                }
                .font(.system(size: 11.5))
                UsageBar(v.usedFraction, color: Theme.usage(v.usedFraction))
            }
        }
        Divider()
        HStack(spacing: 16) {
            StatRow(label: "읽기", value: Fmt.rate(d.readRate))
            StatRow(label: "쓰기", value: Fmt.rate(d.writeRate))
        }
    }
}

// MARK: Network

struct NetworkDetail: View {
    @EnvironmentObject private var m: ResourceMonitor

    var body: some View {
        let n = m.snapshot.network
        let peak = max(m.rxHistory.max() ?? 0, m.txHistory.max() ?? 0, 1024)
        DetailHeader(title: "네트워크", value: "↓ " + Fmt.rate(n.rxRate),
                     caption: "\(n.connectionName) · ↑ \(Fmt.rate(n.txRate))",
                     symbol: n.connectionSymbol, symbolActive: n.primaryKind != nil)
        ChartBox {
            ZStack {
                Sparkline(values: m.rxHistory, maxValue: peak, color: Theme.accent)
                Sparkline(values: m.txHistory, maxValue: peak, color: .orange, filled: false)
            }
        }
        HStack(spacing: 12) {
            LegendItem(label: "다운로드", color: Theme.accent)
            LegendItem(label: "업로드", color: .orange)
            Spacer()
            Text("최대 " + Fmt.rate(peak)).font(.system(size: 10.5)).foregroundStyle(.secondary)
        }
        ForEach(n.interfaces) { iface in
            Divider()
            if iface.kind == .wifi {
                WiFiBlock(iface: iface, wifi: n.wifi)
            } else {
                EthernetBlock(iface: iface)
            }
        }
        if !n.interfaces.contains(where: { $0.kind == .ethernet }) {
            Divider()
            InterfaceTitle(symbol: "cable.connector", name: "Ethernet", detail: nil, status: "연결 안 됨", active: false)
        }
    }
}

struct InterfaceTitle: View {
    let symbol: String
    let name: String
    let detail: String?
    let status: String
    let active: Bool
    var variableValue: Double? = nil

    var body: some View {
        HStack(spacing: 7) {
            Image(systemName: symbol, variableValue: variableValue)
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(active ? Theme.accent : .secondary)
                .frame(width: 16)
            Text(name).font(.system(size: 12, weight: .semibold))
            if let detail {
                Text(detail).font(.system(size: 11.5)).foregroundStyle(.secondary).lineLimit(1)
            }
            Spacer()
            Text(status).font(.system(size: 11)).foregroundStyle(active ? .green : .secondary)
        }
    }
}

struct WiFiBlock: View {
    @EnvironmentObject private var m: ResourceMonitor
    let iface: NetInterface
    let wifi: WiFiInfo?

    var body: some View {
        let connected = wifi?.isConnected == true
        VStack(alignment: .leading, spacing: 6) {
            InterfaceTitle(symbol: "wifi", name: "Wi-Fi",
                           detail: connected ? (wifi?.ssid ?? "이름 숨김") : nil,
                           status: statusText, active: connected, variableValue: wifi?.quality ?? 0)
            if let w = wifi, connected {
                VStack(spacing: 4) {
                    StatRow(label: "신호", value: "\(w.qualityText) · \(w.rssi) dBm")
                    StatRow(label: "채널", value: [w.band, w.channel.map { "ch \($0)" }, w.phyMode]
                        .compactMap { $0 }.joined(separator: " · "))
                    StatRow(label: "링크 속도", value: String(format: "%.0f Mbps", w.txRate))
                    if let ip = iface.ipv4.first { StatRow(label: "IP 주소", value: ip) }
                }
                .padding(.leading, 23)
                if w.ssid == nil {
                    Button {
                        m.requestLocation()
                    } label: {
                        Text(m.locationStatus == .notDetermined ? "네트워크 이름 보기…" : "위치 서비스 설정 열기…")
                            .font(.system(size: 11))
                    }
                    .buttonStyle(.link)
                    .padding(.leading, 23)
                    .help("macOS는 위치 권한이 있어야 Wi-Fi 이름을 알려줍니다")
                }
            }
        }
    }

    private var statusText: String {
        guard let w = wifi else { return "없음" }
        if !w.powerOn { return "꺼짐" }
        return w.isConnected ? "연결됨" : "연결 안 됨"
    }
}

struct EthernetBlock: View {
    let iface: NetInterface

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            InterfaceTitle(symbol: "cable.connector", name: iface.displayName, detail: nil,
                           status: "연결됨", active: true)
            VStack(spacing: 4) {
                StatRow(label: "링크 속도", value: Fmt.linkSpeed(iface.linkSpeed))
                if let ip = iface.ipv4.first { StatRow(label: "IP 주소", value: ip) }
                StatRow(label: "속도", value: "↓ \(Fmt.rate(iface.rxRate))  ↑ \(Fmt.rate(iface.txRate))")
            }
            .padding(.leading, 23)
        }
    }
}

// MARK: Temperature

struct TemperatureDetail: View {
    @EnvironmentObject private var m: ResourceMonitor

    var body: some View {
        let t = m.snapshot.temperature
        DetailHeader(title: "온도", value: String(format: "%.0f°C", t.cpuAverage), caption: "CPU · SoC 다이 평균")
        ChartBox {
            Sparkline(values: m.tempHistory, maxValue: 100, minValue: 20, color: Theme.temperature(t.cpuAverage))
        }
        VStack(spacing: 5) {
            StatRow(label: "CPU 최고", value: String(format: "%.0f°C", t.cpuMax))
            if let ssd = t.ssd { StatRow(label: "SSD", value: String(format: "%.0f°C", ssd)) }
            if let b = t.battery { StatRow(label: "배터리", value: String(format: "%.0f°C", b)) }
        }
    }
}

// MARK: Battery

struct BatteryDetail: View {
    @EnvironmentObject private var m: ResourceMonitor

    var body: some View {
        let b = m.snapshot.battery
        let low = b.percent <= 20 && !b.onAC
        DetailHeader(title: "배터리", value: "\(b.percent)%", caption: stateText(b))
        UsageBar(Double(b.percent) / 100, color: low ? .red : (b.isCharging ? .green : Theme.accent), height: 8)
        VStack(spacing: 5) {
            if let w = b.watts, w != 0 {
                StatRow(label: w > 0 ? "충전 전력" : "소비 전력", value: String(format: "%.1f W", abs(w)))
            }
            if let h = b.health { StatRow(label: "최대 용량", value: Fmt.percent(h)) }
            if let c = b.cycleCount { StatRow(label: "충전 사이클", value: "\(c)회") }
            if let t = b.temperature { StatRow(label: "온도", value: String(format: "%.0f°C", t)) }
            if b.onAC, let aw = b.adapterWatts { StatRow(label: "전원 어댑터", value: "\(aw)W") }
        }
    }

    private func stateText(_ b: BatteryStats) -> String {
        if b.isCharging {
            return "충전 중" + (b.timeToFull.map { " · 완충까지 \(Fmt.minutes($0))" } ?? "")
        }
        if b.onAC { return b.isCharged || b.percent >= 100 ? "완충됨 · 전원 연결됨" : "전원 연결됨 · 충전 대기" }
        return "배터리 사용 중" + (b.timeToEmpty.map { " · \(Fmt.minutes($0)) 남음" } ?? "")
    }
}

// MARK: Bluetooth

struct BluetoothDetail: View {
    @EnvironmentObject private var m: ResourceMonitor

    var body: some View {
        let bt = m.snapshot.bluetooth
        DetailHeader(title: "블루투스",
                     value: !bt.available ? "…" : (bt.poweredOn ? "\(bt.connected.count)대" : "끔"),
                     caption: !bt.available ? "확인 중…" : (bt.poweredOn ? "연결된 기기" : "블루투스가 꺼져 있어요"))
        if bt.poweredOn {
            if bt.connected.isEmpty {
                Text("연결된 기기가 없어요").font(.system(size: 11.5)).foregroundStyle(.secondary)
            } else {
                VStack(spacing: 7) { ForEach(bt.connected) { DeviceRow(device: $0) } }
            }
            if !bt.paired.isEmpty {
                SubHeading(text: "페어링된 기기")
                VStack(spacing: 7) { ForEach(bt.paired) { DeviceRow(device: $0) } }
            }
        }
    }
}

struct DeviceRow: View {
    let device: BTDevice

    var body: some View {
        HStack(spacing: 7) {
            Image(systemName: device.symbol)
                .font(.system(size: 12))
                .foregroundStyle(device.connected ? Theme.accent : .secondary)
                .frame(width: 16)
            Text(device.name).lineLimit(1)
                .foregroundStyle(device.connected ? .primary : .secondary)
            Spacer()
            ForEach(device.batteries, id: \.label) { b in
                HStack(spacing: 2) {
                    if b.label != "배터리" { Text(b.label).foregroundStyle(.secondary) }
                    Text("\(b.percent)%")
                        .monospacedDigit()
                        .foregroundStyle(b.percent <= 20 ? .red : .primary)
                }
            }
        }
        .font(.system(size: 11.5))
    }
}
