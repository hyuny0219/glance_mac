import AppKit
import SwiftUI

/// System Settings–style grouped form, shown in its own window ("Glance 설정…").
struct SettingsForm: View {
    @EnvironmentObject private var m: ResourceMonitor

    var body: some View {
        Form {
            Section {
                Picker("표시 방식", selection: $m.menuBarStyle) {
                    ForEach(MenuBarStyle.allCases) { Text($0.title).tag($0) }
                }
                if m.menuBarStyle != .icon {
                    ForEach(StatusMetric.allCases) { metric in
                        Toggle(metric.title, isOn: Binding(
                            get: { m.enabledMetrics.contains(metric) },
                            set: { on in
                                if on { m.enabledMetrics.insert(metric) } else { m.enabledMetrics.remove(metric) }
                            }))
                    }
                }
            } header: {
                Text("메뉴바")
            } footer: {
                Text("공간이 부족하면 뒤쪽 항목부터 자동으로 숨겨집니다.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }

            Section("일반") {
                Picker("갱신 주기", selection: $m.interval) {
                    Text("1초").tag(1.0)
                    Text("2초").tag(2.0)
                    Text("5초").tag(5.0)
                }
                Toggle("로그인 시 자동 실행", isOn: Binding(
                    get: { m.launchAtLogin },
                    set: { m.setLaunchAtLogin($0) }))
            }
        }
        .formStyle(.grouped)
        .toggleStyle(.switch)
        .frame(width: 420)
        .fixedSize(horizontal: false, vertical: true)
    }
}

@MainActor
final class SettingsWindowController {
    private var window: NSWindow?
    private let monitor: ResourceMonitor

    init(monitor: ResourceMonitor) {
        self.monitor = monitor
    }

    func show() {
        if window == nil {
            let host = NSHostingController(rootView: SettingsForm().environmentObject(monitor))
            host.sizingOptions = .preferredContentSize
            let w = NSWindow(contentViewController: host)
            w.title = "Glance 설정"
            w.styleMask = [.titled, .closable]
            w.isReleasedWhenClosed = false
            w.center()
            window = w
        }
        NSApp.activate(ignoringOtherApps: true)
        window?.makeKeyAndOrderFront(nil)
    }
}
