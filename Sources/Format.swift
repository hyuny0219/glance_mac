import SwiftUI

enum Fmt {
    /// Human readable bytes. `base` 1024 for memory, 1000 for disk/network (matches Finder/Activity Monitor).
    static func bytes(_ v: Double, base: Double = 1000) -> String {
        let units = ["B", "KB", "MB", "GB", "TB"]
        var value = max(0, v)
        var i = 0
        while value >= base && i < units.count - 1 {
            value /= base
            i += 1
        }
        let fmt = (i == 0 || value >= 100) ? "%.0f %@" : "%.1f %@"
        return String(format: fmt, value, units[i])
    }

    static func bytes(_ v: UInt64, base: Double = 1000) -> String { bytes(Double(v), base: base) }

    static func rate(_ v: Double) -> String { bytes(v) + "/s" }

    /// Very compact rate for the menu bar, e.g. "12K", "1.2M".
    static func compactRate(_ v: Double) -> String {
        let units = ["B", "K", "M", "G"]
        var value = max(0, v)
        var i = 0
        while value >= 999.5 && i < units.count - 1 {   // so 999.6K becomes 1.0M, not 1000K
            value /= 1000
            i += 1
        }
        if i == 0 { return String(format: "%.0f%@", value, units[i]) }
        // 9.96 would print as "10.0" with one decimal; switch to integer before it rounds up.
        return value >= 9.95 ? String(format: "%.0f%@", value, units[i]) : String(format: "%.1f%@", value, units[i])
    }

    static func percent(_ fraction: Double) -> String {
        String(format: "%.0f%%", max(0, min(1, fraction)) * 100)
    }

    static func temp(_ c: Double) -> String { String(format: "%.0f°", c) }

    static func minutes(_ m: Int) -> String {
        m >= 60 ? "\(m / 60)시간 \(m % 60)분" : "\(m)분"
    }

    static func linkSpeed(_ bps: UInt64) -> String {
        guard bps > 0 else { return "-" }
        let mbps = Double(bps) / 1_000_000
        return mbps >= 1000 ? String(format: "%.1f Gbps", mbps / 1000) : String(format: "%.0f Mbps", mbps)
    }
}

extension Color {
    static func temp(_ c: Double) -> Color {
        switch c {
        case ..<65: return .green
        case ..<85: return .orange
        default: return .red
        }
    }

    static func level(_ fraction: Double) -> Color {
        switch fraction {
        case ..<0.6: return .green
        case ..<0.85: return .orange
        default: return .red
        }
    }
}
