import AppKit
import Darwin
import Foundation
import ServiceManagement
import SwiftUI
import UserNotifications

@main
struct SystemGuardApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @StateObject private var monitor = SystemMonitor.shared

    init() {
        if CommandLine.arguments.contains("--login-item-status") {
            print(LoginItemSupport.statusText())
            Foundation.exit(0)
        }

        if CommandLine.arguments.contains("--unregister-login-item") {
            LoginItemSupport.unregisterAndExit()
        }

        if CommandLine.arguments.contains("--self-test") {
            SystemCollector.runSelfTests()
            print("self-test ok")
            Foundation.exit(0)
        }

        if CommandLine.arguments.contains("--snapshot") {
            let raw = SystemCollector.collect()
            print(DiagnosticFormatter.rawSnapshotText(raw))
            Foundation.exit(0)
        }

        Task { @MainActor in
            await SystemMonitor.shared.start()
        }
    }

    var body: some Scene {
        MenuBarExtra {
            GuardMenuView()
                .environmentObject(monitor)
                .frame(width: 600)
        } label: {
            PressureMenuBarLabel(
                level: monitor.level,
                progress: monitor.snapshot.pressureProgress,
                title: monitor.menuTitle
            )
        }
        .menuBarExtraStyle(.window)

        Window("System Guard Settings", id: "settings") {
            SettingsView()
                .environmentObject(monitor)
                .frame(width: 560, height: 620)
        }
        .defaultSize(width: 560, height: 620)
        .windowResizability(.contentSize)
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { _, _ in }
    }
}

enum LoginItemSupport {
    static func statusText() -> String {
        switch SMAppService.mainApp.status {
        case .enabled:
            return "Enabled"
        case .notRegistered:
            return "Not registered"
        case .requiresApproval:
            return "Requires approval"
        case .notFound:
            return "Not found"
        @unknown default:
            return "Unknown"
        }
    }

    static func unregisterAndExit() {
        switch SMAppService.mainApp.status {
        case .notRegistered, .notFound:
            print("login item not registered")
            Foundation.exit(0)
        default:
            break
        }

        let semaphore = DispatchSemaphore(value: 0)
        var unregisterError: Error?

        Task {
            do {
                try await SMAppService.mainApp.unregister()
            } catch {
                unregisterError = error
            }
            semaphore.signal()
        }

        semaphore.wait()

        if let unregisterError {
            FileHandle.standardError.write(Data("login item unregister failed: \(unregisterError.localizedDescription)\n".utf8))
            Foundation.exit(1)
        }

        print("login item unregistered")
        Foundation.exit(0)
    }
}

struct PressureMenuBarLabel: View {
    let level: GuardLevel
    let progress: Double
    let title: String

    var body: some View {
        HStack(spacing: 5) {
            PressureBarsIcon(level: level, progress: progress)
                .frame(width: 18, height: 18)
            Text(title)
                .font(.system(size: 12, weight: .semibold, design: .rounded))
                .monospacedDigit()
        }
        .accessibilityLabel("System Guard \(title)")
    }
}

struct PressureBarsIcon: View {
    let level: GuardLevel
    let progress: Double

    var body: some View {
        HStack(alignment: .bottom, spacing: 2) {
            ForEach(0..<4, id: \.self) { index in
                RoundedRectangle(cornerRadius: 1.5, style: .continuous)
                    .fill(barColor(index: index))
                    .frame(width: 3.5, height: CGFloat(6 + index * 3))
            }
        }
        .overlay(alignment: .topTrailing) {
            if level == .critical {
                Circle()
                    .fill(Color.red)
                    .frame(width: 5, height: 5)
                    .offset(x: 2, y: -2)
            }
        }
    }

    private func barColor(index: Int) -> Color {
        let threshold = Double(index + 1) / 4.0
        if progress >= threshold {
            return level.color
        }
        return Color.secondary.opacity(0.35)
    }
}

struct GuardMenuView: View {
    @EnvironmentObject private var monitor: SystemMonitor
    @Environment(\.openWindow) private var openWindow
    private let metricColumns = [
        GridItem(.flexible(), spacing: 12),
        GridItem(.flexible(), spacing: 12)
    ]

    var body: some View {
        ZStack {
            GuardSurfaceBackground(level: monitor.level)

            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    header

                    pressureSection
                    historySection
                    groupsSection
                    staleSection
                    topProcessesSection

                    actions
                }
                .padding(18)
            }
        }
        .frame(maxHeight: 780)
    }

    private var header: some View {
        HStack(alignment: .center, spacing: 18) {
            PressureDial(level: monitor.level, progress: monitor.snapshot.pressureProgress)

            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 9) {
                    Text("System Guard")
                        .font(.system(size: 22, weight: .semibold, design: .serif))
                    StatusChip(title: monitor.level.title, color: monitor.level.color)
                }

                Text(monitor.snapshot.headerDetailText)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)

                if let reason = monitor.snapshot.primaryReason {
                    HStack(spacing: 7) {
                        Image(systemName: monitor.level == .critical ? "exclamationmark.octagon.fill" : "exclamationmark.triangle.fill")
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(monitor.level.color)
                        Text(reason)
                            .font(.caption.weight(.medium))
                            .foregroundStyle(.primary.opacity(0.86))
                            .lineLimit(1)
                    }
                }
            }

            Spacer(minLength: 12)

            VStack(alignment: .trailing, spacing: 6) {
                Text(monitor.snapshot.freePercentText)
                    .font(.system(size: monitor.snapshot.isPlaceholder ? 25 : 40, weight: .semibold, design: .rounded))
                    .monospacedDigit()
                    .lineLimit(1)
                    .minimumScaleFactor(0.75)
                Text("free memory")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                    .textCase(.uppercase)
            }
        }
        .padding(18)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .stroke(monitor.level.color.opacity(0.28), lineWidth: 1)
        }
        .shadow(color: monitor.level.color.opacity(0.10), radius: 18, x: 0, y: 10)
    }

    private var pressureSection: some View {
        SectionPanel(title: "Pressure", systemImage: "memorychip", accessory: "poll \(GuardSettings.pollSeconds)s") {
            LazyVGrid(columns: metricColumns, spacing: 12) {
                MetricTile(
                    title: "Free",
                    value: monitor.snapshot.freePercentText,
                    detail: "warn <= \(GuardSettings.warningFreePercent)%",
                    systemImage: "memorychip",
                    tint: monitor.level.color
                )
                MetricTile(
                    title: "Compressor",
                    value: monitor.snapshot.compressorGiB.formattedGiB,
                    detail: "warn \(GuardSettings.warningCompressorGiB.formattedGiB)",
                    systemImage: "arrow.down.forward.and.arrow.up.backward",
                    tint: monitor.snapshot.compressorGiB >= GuardSettings.warningCompressorGiB ? .orange : .blue
                )
                MetricTile(
                    title: "Swap",
                    value: monitor.snapshot.swapGiB.formattedGiB,
                    detail: "\(monitor.snapshot.swapfileCount) files",
                    systemImage: "externaldrive",
                    tint: monitor.snapshot.swapGiB >= GuardSettings.warningSwapGiB ? .orange : .green
                )
                MetricTile(
                    title: "Alerts",
                    value: monitor.notificationStatusText,
                    detail: monitor.notificationStatusText == "Allowed" ? "ready" : "needs attention",
                    systemImage: "bell.badge",
                    tint: monitor.notificationStatusText == "Allowed" ? .green : .orange
                )
            }

            if !monitor.snapshot.reasons.isEmpty {
                VStack(alignment: .leading, spacing: 8) {
                    ForEach(monitor.snapshot.reasons, id: \.self) { reason in
                        ReasonBanner(text: reason, level: monitor.level)
                    }
                }
                .padding(.top, 2)
            }
        }
    }

    private var groupsSection: some View {
        SectionPanel(title: "Workload Groups", systemImage: "square.stack.3d.up", accessory: "\(monitor.snapshot.groups.count) groups") {
            let maxUsage = max(monitor.snapshot.groups.map(\.totalRSSGiB).max() ?? 1, 1)
            ForEach(monitor.snapshot.groups.prefix(8)) { group in
                GroupUsageRow(group: group, maxUsage: maxUsage)
            }
        }
    }

    private var historySection: some View {
        SectionPanel(title: "Recent Pressure", systemImage: "chart.xyaxis.line", accessory: "\(monitor.history.count) samples") {
            PressureHistoryStrip(samples: Array(monitor.history.suffix(30)))
        }
    }

    private var staleSection: some View {
        SectionPanel(title: "Browser Automation", systemImage: "globe.badge.chevron.backward", accessory: "\(monitor.snapshot.staleBrowserProcesses.count) stale") {
            if monitor.snapshot.staleBrowserProcesses.isEmpty {
                EmptyStateRow(systemImage: "checkmark.circle", title: "No stale browser automation", subtitle: "No cleanup candidates observed.", tint: .green)
            } else {
                ForEach(monitor.snapshot.staleBrowserProcesses.prefix(5)) { process in
                    ProcessUsageRow(process: process, accessory: process.elapsed)
                }
            }
        }
    }

    private var topProcessesSection: some View {
        SectionPanel(title: "Top Processes", systemImage: "list.bullet.rectangle", accessory: "by RSS") {
            ForEach(monitor.snapshot.topProcesses.prefix(7)) { process in
                ProcessUsageRow(process: process, accessory: process.kind.title)
            }
        }
    }

    private var actions: some View {
        SectionPanel(title: "Actions", systemImage: "bolt") {
            LazyVGrid(columns: metricColumns, spacing: 12) {
                UtilityActionButton(title: "Check Now", systemImage: "arrow.clockwise", tint: .blue) {
                    Task { await monitor.refreshNow() }
                }

                UtilityActionButton(title: "Export", systemImage: "square.and.arrow.up", tint: .teal) {
                    monitor.exportSnapshot()
                }

                UtilityActionButton(title: monitor.notificationActionTitle, systemImage: monitor.notificationActionIcon, tint: .orange) {
                    monitor.handleNotificationAction()
                }

                UtilityActionButton(title: "Settings", systemImage: "slider.horizontal.3", tint: .indigo) {
                    openWindow(id: "settings")
                    NSApp.activate(ignoringOtherApps: true)
                }

                UtilityActionButton(title: "Clean Stale", systemImage: "sparkles", tint: .green, isDisabled: monitor.snapshot.staleBrowserProcesses.isEmpty) {
                    confirmStaleBrowserCleanup(
                        title: "Clean stale browser automation?",
                        message: "System Guard will send SIGTERM to these stale automation candidates.",
                        confirmTitle: "Clean Stale",
                        isDestructive: false
                    ) {
                        monitor.cleanStaleBrowserAutomation()
                    }
                }

                UtilityActionButton(title: "Force Kill", systemImage: "xmark.octagon", tint: .red, isDestructive: true, isDisabled: monitor.snapshot.staleBrowserProcesses.isEmpty) {
                    confirmStaleBrowserCleanup(
                        title: "Force-kill stale browser automation?",
                        message: "System Guard will send SIGKILL to these stale automation candidates.",
                        confirmTitle: "Force Kill",
                        isDestructive: true
                    ) {
                        monitor.forceKillStaleBrowserAutomation()
                    }
                }

                UtilityActionButton(title: "Quit Docker", systemImage: "shippingbox", tint: .red, isDestructive: true) {
                    confirmDestructiveAction(
                        title: "Quit Docker Desktop?",
                        message: "This asks Docker Desktop to quit. Running containers and local Docker-dependent workflows may stop.",
                        confirmTitle: "Quit Docker"
                    ) {
                        monitor.quitDockerDesktop()
                    }
                }

                UtilityActionButton(title: "Activity", systemImage: "waveform.path.ecg", tint: .mint) {
                    NSWorkspace.shared.open(URL(fileURLWithPath: "/System/Applications/Utilities/Activity Monitor.app"))
                }
            }
        }
    }

    private func confirmStaleBrowserCleanup(
        title: String,
        message: String,
        confirmTitle: String,
        isDestructive: Bool,
        perform: () -> Void
    ) {
        let processes = monitor.snapshot.staleBrowserProcesses
        guard !processes.isEmpty else { return }

        let processLines = StaleProcessConfirmationFormatter.lines(for: processes)

        confirmDestructiveAction(
            title: title,
            message: "\(message)\n\n\(processLines)",
            confirmTitle: confirmTitle,
            isDestructive: isDestructive,
            perform: perform
        )
    }

    private func confirmDestructiveAction(
        title: String,
        message: String,
        confirmTitle: String,
        isDestructive: Bool = true,
        perform: () -> Void
    ) {
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = message
        alert.alertStyle = isDestructive ? .critical : .warning
        alert.addButton(withTitle: confirmTitle)
        alert.addButton(withTitle: "Cancel")

        let response = alert.runModal()
        if response == .alertFirstButtonReturn {
            perform()
        }
    }
}

struct GuardSurfaceBackground: View {
    let level: GuardLevel

    var body: some View {
        ZStack {
            LinearGradient(
                colors: [
                    Color(nsColor: .windowBackgroundColor),
                    Color(nsColor: .controlBackgroundColor),
                    level.color.opacity(0.06)
                ],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )

            VStack(spacing: 0) {
                ForEach(0..<18, id: \.self) { _ in
                    Rectangle()
                        .fill(Color.primary.opacity(0.025))
                        .frame(height: 1)
                    Spacer(minLength: 22)
                }
            }
            .allowsHitTesting(false)
        }
        .ignoresSafeArea()
    }
}

struct PressureDial: View {
    let level: GuardLevel
    let progress: Double

    var body: some View {
        ZStack {
            Circle()
                .fill(level.color.opacity(0.10))
                .frame(width: 68, height: 68)

            Circle()
                .stroke(Color.primary.opacity(0.08), lineWidth: 7)
                .frame(width: 62, height: 62)

            Circle()
                .trim(from: 0, to: progress)
                .stroke(level.color, style: StrokeStyle(lineWidth: 7, lineCap: .round))
                .frame(width: 62, height: 62)
                .rotationEffect(.degrees(-90))

            Image(systemName: level.symbolName)
                .font(.system(size: 26, weight: .bold))
                .foregroundStyle(level.color)
        }
        .accessibilityLabel(level.title)
    }
}

struct SectionPanel<Content: View>: View {
    let title: String
    let systemImage: String
    var accessory: String?
    @ViewBuilder let content: Content

    init(title: String, systemImage: String, accessory: String? = nil, @ViewBuilder content: () -> Content) {
        self.title = title
        self.systemImage = systemImage
        self.accessory = accessory
        self.content = content()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                Label(title, systemImage: systemImage)
                    .font(.headline.weight(.semibold))
                    .foregroundStyle(.primary)
                Spacer()
                if let accessory {
                    Text(accessory)
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.secondary)
                        .monospacedDigit()
                }
            }

            content
        }
        .padding(.vertical, 2)
    }
}

struct StatusChip: View {
    let title: String
    let color: Color

    var body: some View {
        Text(title)
            .font(.caption.weight(.bold))
            .foregroundStyle(color)
            .textCase(.uppercase)
            .tracking(0.7)
            .padding(.horizontal, 9)
            .padding(.vertical, 5)
            .background(color.opacity(0.12), in: RoundedRectangle(cornerRadius: 6, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .stroke(color.opacity(0.22), lineWidth: 1)
            }
    }
}

struct MetricTile: View {
    let title: String
    let value: String
    var detail: String?
    let systemImage: String
    let tint: Color

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Image(systemName: systemImage)
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundStyle(tint)
                    .frame(width: 32, height: 32)
                    .background(tint.opacity(0.12), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                Spacer(minLength: 8)
                Text(title)
                    .font(.caption.weight(.bold))
                    .foregroundStyle(.secondary)
                    .textCase(.uppercase)
                    .lineLimit(1)
            }

            VStack(alignment: .leading, spacing: 3) {
                HStack(alignment: .firstTextBaseline, spacing: 5) {
                    Text(value)
                        .font(.system(size: 20, weight: .semibold, design: .rounded))
                        .monospacedDigit()
                        .lineLimit(1)
                        .minimumScaleFactor(0.72)
                    if let detail {
                        Text(detail)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                }
            }
        }
        .frame(maxWidth: .infinity, minHeight: 82, alignment: .leading)
        .padding(13)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay(alignment: .bottom) {
            Rectangle()
                .fill(tint.opacity(0.45))
                .frame(height: 2)
                .clipShape(RoundedRectangle(cornerRadius: 2, style: .continuous))
                .padding(.horizontal, 12)
        }
        .overlay {
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .stroke(Color.primary.opacity(0.06), lineWidth: 1)
        }
    }
}

struct ReasonBanner: View {
    let text: String
    let level: GuardLevel

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: level == .critical ? "exclamationmark.octagon.fill" : "exclamationmark.triangle.fill")
                .foregroundStyle(level.color)
            Text(text)
                .font(.callout)
                .foregroundStyle(.primary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(12)
        .background(level.color.opacity(0.11), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .stroke(level.color.opacity(0.18), lineWidth: 1)
        }
    }
}

struct PressureHistoryStrip: View {
    let samples: [HistorySample]

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            if samples.isEmpty {
                EmptyStateRow(systemImage: "clock", title: "Collecting pressure history", subtitle: "Waiting for more samples.", tint: .secondary)
            } else {
                HStack(alignment: .bottom, spacing: 4) {
                    ForEach(samples) { sample in
                        RoundedRectangle(cornerRadius: 3, style: .continuous)
                            .fill(sample.level.color.gradient)
                            .frame(width: 12, height: sample.barHeight)
                            .help("\(sample.freePercent)% free, \(sample.swapGiB.formattedGiB) swap")
                    }
                    Spacer(minLength: 0)
                }
                .frame(height: 54)

                HStack {
                    Text("low pressure")
                    Spacer()
                    Text("high pressure")
                }
                .font(.caption2.weight(.semibold))
                .foregroundStyle(.secondary)
            }
        }
        .padding(14)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .stroke(Color.primary.opacity(0.06), lineWidth: 1)
        }
    }
}

struct GroupUsageRow: View {
    let group: ProcessGroup
    let maxUsage: Double

    var body: some View {
        VStack(alignment: .leading, spacing: 9) {
            HStack {
                HStack(spacing: 8) {
                    Image(systemName: group.symbolName)
                        .font(.system(size: 13, weight: .bold))
                        .foregroundStyle(group.tint)
                        .frame(width: 24, height: 24)
                        .background(group.tint.opacity(0.11), in: RoundedRectangle(cornerRadius: 7, style: .continuous))
                    Text(group.name)
                        .font(.callout.weight(.medium))
                        .lineLimit(1)
                }
                Spacer()
                Text("\(group.totalRSSGiB.formattedGiB) · \(group.processCount)")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
            }

            GeometryReader { proxy in
                ZStack(alignment: .leading) {
                    Capsule()
                        .fill(Color.primary.opacity(0.08))
                    Capsule()
                        .fill(group.tint.gradient)
                        .frame(width: max(6, proxy.size.width * min(group.totalRSSGiB / maxUsage, 1)))
                }
            }
            .frame(height: 8)
        }
        .padding(12)
        .background(Color(nsColor: .windowBackgroundColor).opacity(0.58), in: RoundedRectangle(cornerRadius: 11, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 11, style: .continuous)
                .stroke(Color.primary.opacity(0.05), lineWidth: 1)
        }
    }
}

struct ProcessUsageRow: View {
    let process: ProcessInfoSnapshot
    let accessory: String

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: process.kind.symbolName)
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(process.kind.tint)
                .frame(width: 32, height: 32)
                .background(process.kind.tint.opacity(0.11), in: RoundedRectangle(cornerRadius: 8, style: .continuous))

            VStack(alignment: .leading, spacing: 3) {
                Text(process.shortName)
                    .font(.callout.weight(.medium))
                    .lineLimit(1)
                    .truncationMode(.middle)
                Text("pid \(process.pid) / \(accessory)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }

            Spacer(minLength: 8)

            Text(process.rssGiB.formattedGiB)
                .font(.callout.weight(.semibold))
                .monospacedDigit()
                .foregroundStyle(.secondary)
        }
        .padding(10)
        .background(Color(nsColor: .windowBackgroundColor).opacity(0.55), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .stroke(Color.primary.opacity(0.05), lineWidth: 1)
        }
    }
}

struct EmptyStateRow: View {
    let systemImage: String
    let title: String
    var subtitle: String?
    let tint: Color

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: systemImage)
                .foregroundStyle(tint)
                .font(.system(size: 15, weight: .semibold))
                .frame(width: 22)
            VStack(alignment: .leading, spacing: 3) {
                Text(title)
                    .font(.callout.weight(.medium))
                    .foregroundStyle(.primary.opacity(0.82))
                if let subtitle {
                    Text(subtitle)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            Spacer()
        }
        .padding(12)
        .background(Color(nsColor: .windowBackgroundColor).opacity(0.50), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
    }
}

struct UtilityActionButton: View {
    let title: String
    let systemImage: String
    let tint: Color
    var isDestructive = false
    var isDisabled = false
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 9) {
                Image(systemName: systemImage)
                    .font(.system(size: 15, weight: .semibold))
                Text(title)
                    .font(.callout.weight(.medium))
                    .lineLimit(1)
                Spacer(minLength: 0)
            }
            .frame(maxWidth: .infinity)
            .padding(.horizontal, 12)
            .padding(.vertical, 11)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .foregroundStyle(isDestructive ? Color.red : Color.primary)
        .background((isDisabled ? Color(nsColor: .windowBackgroundColor).opacity(0.35) : tint.opacity(0.10)), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .stroke((isDestructive ? Color.red : tint).opacity(isDisabled ? 0.08 : 0.18), lineWidth: 1)
        }
        .disabled(isDisabled)
        .opacity(isDisabled ? 0.45 : 1)
    }
}

struct SettingsView: View {
    @EnvironmentObject private var monitor: SystemMonitor
    @AppStorage("warningSwapGiB") private var warningSwapGiB = 6.0
    @AppStorage("criticalSwapGiB") private var criticalSwapGiB = 10.0
    @AppStorage("warningCompressorGiB") private var warningCompressorGiB = 10.0
    @AppStorage("criticalCompressorGiB") private var criticalCompressorGiB = 16.0
    @AppStorage("trendWindowMinutes") private var trendWindowMinutes = 10
    @AppStorage("warningCompressorTrendGiB") private var warningCompressorTrendGiB = 2.0
    @AppStorage("warningSwapTrendGiB") private var warningSwapTrendGiB = 1.0
    @AppStorage("warningFreePercent") private var warningFreePercent = 25
    @AppStorage("criticalFreePercent") private var criticalFreePercent = 10
    @AppStorage("staleAutomationMinutes") private var staleAutomationMinutes = 45
    @AppStorage("pollSeconds") private var pollSeconds = 45

    var body: some View {
        TabView {
            settingsPage {
                SettingsHeader(level: monitor.level, title: "Thresholds", subtitle: monitor.level.title, systemImage: "gauge.medium")

                SettingsPanel(title: "Pressure Thresholds", systemImage: "gauge.medium") {
                    SettingsDoubleRow(title: "Warning swap", unit: "GiB", value: $warningSwapGiB)
                    SettingsDoubleRow(title: "Critical swap", unit: "GiB", value: $criticalSwapGiB)
                    SettingsDoubleRow(title: "Warning compressor", unit: "GiB", value: $warningCompressorGiB)
                    SettingsDoubleRow(title: "Critical compressor", unit: "GiB", value: $criticalCompressorGiB)
                    SettingsIntRow(title: "Warning free memory", unit: "%", value: $warningFreePercent)
                    SettingsIntRow(title: "Critical free memory", unit: "%", value: $criticalFreePercent)
                }

                SettingsPanel(title: "Trend Detection", systemImage: "chart.line.uptrend.xyaxis") {
                    SettingsIntRow(title: "Trend window", unit: "min", value: $trendWindowMinutes)
                    SettingsDoubleRow(title: "Compressor growth", unit: "GiB", value: $warningCompressorTrendGiB)
                    SettingsDoubleRow(title: "Swap growth", unit: "GiB", value: $warningSwapTrendGiB)
                }

                settingsActions
            }
            .tabItem {
                Label("Thresholds", systemImage: "gauge.medium")
            }

            settingsPage {
                SettingsHeader(level: monitor.level, title: "Monitoring", subtitle: "Collectors, alerts, and cleanup cadence.", systemImage: "waveform.path.ecg")

                SettingsPanel(title: "Process Detection", systemImage: "rectangle.3.group") {
                    SettingsIntRow(title: "Stale browser automation", unit: "min", value: $staleAutomationMinutes)
                    SettingsIntRow(title: "Poll interval", unit: "sec", value: $pollSeconds)
                }

                SettingsPanel(title: "Notification State", systemImage: "bell.badge") {
                    SettingsInfoRow(title: "Status", value: monitor.notificationStatusText)
                    SettingsInfoRow(title: "Action", value: monitor.notificationActionTitle)
                }

                SettingsPanel(title: "Launch at Login", systemImage: "power") {
                    SettingsInfoRow(title: "Status", value: monitor.loginItemStatusText)
                    HStack(spacing: 12) {
                        Button {
                            Task { await monitor.setLaunchAtLoginEnabled(true) }
                        } label: {
                            Label("Enable", systemImage: "checkmark.circle")
                                .frame(maxWidth: .infinity)
                        }
                        .buttonStyle(.borderedProminent)
                        .disabled(monitor.loginItemStatusText == "Enabled")

                        Button {
                            Task { await monitor.setLaunchAtLoginEnabled(false) }
                        } label: {
                            Label("Disable", systemImage: "xmark.circle")
                                .frame(maxWidth: .infinity)
                        }
                        .buttonStyle(.bordered)
                        .disabled(monitor.loginItemStatusText == "Not registered" || monitor.loginItemStatusText == "Not found")
                    }
                    .controlSize(.large)
                    .padding(14)
                }

                settingsActions
            }
            .tabItem {
                Label("Monitoring", systemImage: "waveform.path.ecg")
            }

            settingsPage {
                SettingsHeader(level: monitor.level, title: "About", subtitle: "Build and runtime context.", systemImage: "info.circle")

                SettingsPanel(title: "Application", systemImage: "app.badge") {
                    SettingsInfoRow(title: "Version", value: appVersionText)
                    SettingsInfoRow(title: "Bundle ID", value: bundleIdentifierText)
                    SettingsInfoRow(title: "Install path", value: Bundle.main.bundlePath)
                }

                SettingsPanel(title: "Runtime", systemImage: "clock.badge.checkmark") {
                    SettingsInfoRow(title: "Last check", value: monitor.snapshot.checkedAtText)
                    SettingsInfoRow(title: "Notification status", value: monitor.notificationStatusText)
                    SettingsInfoRow(title: "Login item", value: monitor.loginItemStatusText)
                    SettingsInfoRow(title: "Log folder", value: "~/Library/Logs/SystemGuard")
                }
            }
            .tabItem {
                Label("About", systemImage: "info.circle")
            }
        }
    }

    @ViewBuilder
    private func settingsPage<Content: View>(@ViewBuilder content: () -> Content) -> some View {
        ZStack {
            GuardSurfaceBackground(level: monitor.level)
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    content()
                }
                .padding(24)
            }
        }
    }

    private var settingsActions: some View {
        HStack(spacing: 12) {
            Button {
                resetDefaults()
            } label: {
                Label("Reset Defaults", systemImage: "arrow.counterclockwise")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.bordered)

            Button {
                Task { await monitor.refreshNow() }
            } label: {
                Label("Apply and Check Now", systemImage: "checkmark.circle")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
        }
        .controlSize(.large)
    }

    private var appVersionText: String {
        let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0.1.0"
        let build = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "1"
        return "\(version) (\(build))"
    }

    private var bundleIdentifierText: String {
        Bundle.main.bundleIdentifier ?? "com.aryan.systemguard"
    }

    private func resetDefaults() {
        warningSwapGiB = 6
        criticalSwapGiB = 10
        warningCompressorGiB = 10
        criticalCompressorGiB = 16
        trendWindowMinutes = 10
        warningCompressorTrendGiB = 2
        warningSwapTrendGiB = 1
        warningFreePercent = 25
        criticalFreePercent = 10
        staleAutomationMinutes = 45
        pollSeconds = 45
        Task {
            await monitor.refreshNow()
        }
    }
}

struct SettingsHeader: View {
    let level: GuardLevel
    let title: String
    let subtitle: String
    let systemImage: String

    var body: some View {
        HStack(spacing: 14) {
            Image(systemName: systemImage)
                .font(.system(size: 22, weight: .bold))
                .foregroundStyle(level.color)
                .frame(width: 46, height: 46)
                .background(level.color.opacity(0.12), in: RoundedRectangle(cornerRadius: 12, style: .continuous))

            VStack(alignment: .leading, spacing: 4) {
                Text(title)
                    .font(.system(size: 22, weight: .semibold, design: .serif))
                Text(subtitle)
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }

            Spacer()
        }
        .padding(16)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
    }
}

struct SettingsPanel<Content: View>: View {
    let title: String
    let systemImage: String
    @ViewBuilder let content: Content

    init(title: String, systemImage: String, @ViewBuilder content: () -> Content) {
        self.title = title
        self.systemImage = systemImage
        self.content = content()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Label(title, systemImage: systemImage)
                .font(.headline.weight(.semibold))

            VStack(spacing: 0) {
                content
            }
            .background(Color(nsColor: .windowBackgroundColor).opacity(0.60), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .stroke(Color.primary.opacity(0.06), lineWidth: 1)
            }
        }
    }
}

struct SettingsDoubleRow: View {
    let title: String
    let unit: String
    @Binding var value: Double

    var body: some View {
        SettingsRowContainer(title: title, unit: unit) {
            TextField("", value: $value, format: .number.precision(.fractionLength(0...1)))
                .textFieldStyle(.roundedBorder)
                .multilineTextAlignment(.trailing)
                .monospacedDigit()
                .frame(width: 82)
        }
    }
}

struct SettingsIntRow: View {
    let title: String
    let unit: String
    @Binding var value: Int

    var body: some View {
        SettingsRowContainer(title: title, unit: unit) {
            TextField("", value: $value, format: .number)
                .textFieldStyle(.roundedBorder)
                .multilineTextAlignment(.trailing)
                .monospacedDigit()
                .frame(width: 82)
        }
    }
}

struct SettingsInfoRow: View {
    let title: String
    let value: String

    var body: some View {
        HStack(spacing: 12) {
            Text(title)
                .font(.callout.weight(.medium))
            Spacer(minLength: 16)
            Text(value)
                .font(.callout)
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .truncationMode(.middle)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .overlay(alignment: .bottom) {
            Rectangle()
                .fill(Color.primary.opacity(0.05))
                .frame(height: 1)
                .padding(.leading, 14)
        }
    }
}

struct SettingsRowContainer<Field: View>: View {
    let title: String
    let unit: String
    @ViewBuilder let field: Field

    init(title: String, unit: String, @ViewBuilder field: () -> Field) {
        self.title = title
        self.unit = unit
        self.field = field()
    }

    var body: some View {
        HStack(spacing: 12) {
            Text(title)
                .font(.callout.weight(.medium))
            Spacer()
            field
            Text(unit)
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
                .frame(width: 32, alignment: .leading)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .overlay(alignment: .bottom) {
            Rectangle()
                .fill(Color.primary.opacity(0.05))
                .frame(height: 1)
                .padding(.leading, 14)
        }
    }
}

@MainActor
final class SystemMonitor: ObservableObject {
    static let shared = SystemMonitor()

    @Published private(set) var snapshot = GuardSnapshot.empty
    @Published private(set) var level: GuardLevel = .ok
    @Published private(set) var history: [HistorySample] = []
    @Published private(set) var notificationStatusText = "Checking..."
    @Published private(set) var loginItemStatusText = "Checking..."

    private var timerTask: Task<Void, Never>?
    private var staleObservationCounts: [Int32: Int] = [:]
    private var lastNotificationAt: [String: Date] = [:]

    var menuTitle: String {
        if snapshot.isPlaceholder {
            return "Checking"
        }

        switch level {
        case .ok:
            return "OK"
        case .warning:
            return "Warn"
        case .critical:
            return "Critical"
        }
    }

    var notificationActionTitle: String {
        switch notificationStatusText {
        case "Allowed", "Provisional", "Ephemeral":
            return "Test Alert"
        case "Denied":
            return "Open Alerts"
        case "Not requested":
            return "Allow Alerts"
        default:
            return "Alerts"
        }
    }

    var notificationActionIcon: String {
        switch notificationStatusText {
        case "Allowed", "Provisional", "Ephemeral":
            return "bell.badge"
        case "Denied":
            return "gear.badge"
        case "Not requested":
            return "bell.and.waves.left.and.right"
        default:
            return "bell"
        }
    }

    func start() async {
        guard timerTask == nil else { return }
        refreshNotificationStatus()
        refreshLoginItemStatus()
        await refreshNow()

        timerTask = Task { [weak self] in
            while !Task.isCancelled {
                let interval = UInt64(max(15, GuardSettings.pollSeconds)) * 1_000_000_000
                try? await Task.sleep(nanoseconds: interval)
                await self?.refreshNow()
            }
        }
    }

    func refreshNow() async {
        refreshNotificationStatus()
        refreshLoginItemStatus()
        let raw = await Task.detached(priority: .utility) {
            SystemCollector.collect()
        }.value

        let analyzed = analyze(raw)
        snapshot = analyzed.snapshot
        level = analyzed.level
        appendHistory(snapshot: analyzed.snapshot, level: analyzed.level)
        notifyIfNeeded(snapshot: analyzed.snapshot, level: analyzed.level)
    }

    func sendTestNotification() {
        refreshNotificationStatus()
        EventLogger.log("test notification requested")
        sendNotification(
            key: "test-notification",
            title: "System Guard test",
            body: "Notifications are working.",
            minimumGap: 0
        )
    }

    func handleNotificationAction() {
        UNUserNotificationCenter.current().getNotificationSettings { [weak self] settings in
            switch settings.authorizationStatus {
            case .authorized, .provisional, .ephemeral:
                Task { @MainActor in
                    self?.sendTestNotification()
                }
            case .notDetermined:
                guard let monitor = self else { return }
                UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { granted, error in
                    EventLogger.log("notification permission requested granted=\(granted) error=\(error?.localizedDescription ?? "none")")
                    Task { @MainActor in
                        monitor.refreshNotificationStatus()
                        if granted {
                            monitor.sendTestNotification()
                        } else {
                            monitor.openNotificationSettings()
                        }
                    }
                }
            case .denied:
                Task { @MainActor in
                    self?.openNotificationSettings()
                }
            @unknown default:
                Task { @MainActor in
                    self?.openNotificationSettings()
                }
            }
        }
    }

    func setLaunchAtLoginEnabled(_ enabled: Bool) async {
        do {
            if enabled {
                try SMAppService.mainApp.register()
                EventLogger.log("login item registered")
            } else {
                try await SMAppService.mainApp.unregister()
                EventLogger.log("login item unregistered")
            }
            refreshLoginItemStatus()
        } catch {
            loginItemStatusText = "Error: \(error.localizedDescription)"
            EventLogger.log("login item update failed enabled=\(enabled) error=\(error.localizedDescription)")
        }
    }

    func cleanStaleBrowserAutomation() {
        let processes = snapshot.staleBrowserProcesses
        guard !processes.isEmpty else { return }

        for process in processes {
            Darwin.kill(process.pid, SIGTERM)
        }

        EventLogger.log("cleanup browser automation sigterm count=\(processes.count) pids=\(processes.map(\.pid))")

        sendNotification(
            key: "cleanup-browser-automation",
            title: "System Guard cleaned browser automation",
            body: "Sent SIGTERM to \(processes.count) stale process(es).",
            minimumGap: 5
        )

        Task {
            try? await Task.sleep(nanoseconds: 2_000_000_000)
            await refreshNow()
        }
    }

    func forceKillStaleBrowserAutomation() {
        let processes = snapshot.staleBrowserProcesses
        guard !processes.isEmpty else { return }

        for process in processes {
            Darwin.kill(process.pid, SIGKILL)
        }

        EventLogger.log("cleanup browser automation sigkill count=\(processes.count) pids=\(processes.map(\.pid))")

        sendNotification(
            key: "force-cleanup-browser-automation",
            title: "System Guard force-killed stale automation",
            body: "Sent SIGKILL to \(processes.count) stale process(es).",
            minimumGap: 5
        )

        Task {
            try? await Task.sleep(nanoseconds: 1_000_000_000)
            await refreshNow()
        }
    }

    func quitDockerDesktop() {
        let script = """
        tell application "Docker Desktop" to quit
        """
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
        process.arguments = ["-e", script]
        try? process.run()
    }

    func exportSnapshot() {
        let directory = URL(fileURLWithPath: NSHomeDirectory())
            .appendingPathComponent("Library/Logs/SystemGuard", isDirectory: true)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)

        let stamp = ISO8601DateFormatter().string(from: Date()).replacingOccurrences(of: ":", with: "-")
        let fileURL = directory.appendingPathComponent("snapshot-\(stamp).txt")
        try? snapshot.diagnosticText.write(to: fileURL, atomically: true, encoding: .utf8)
        EventLogger.log("exported snapshot path=\(fileURL.path)")
        NSWorkspace.shared.activateFileViewerSelecting([fileURL])
    }

    private func openNotificationSettings() {
        EventLogger.log("opening notification settings")
        let urls = [
            "x-apple.systempreferences:com.apple.Notifications-Settings.extension",
            "x-apple.systempreferences:com.apple.preference.notifications"
        ].compactMap(URL.init(string:))

        for url in urls {
            if NSWorkspace.shared.open(url) {
                return
            }
        }

        NSWorkspace.shared.open(URL(fileURLWithPath: "/System/Applications/System Settings.app"))
    }

    private func analyze(_ raw: RawSnapshot) -> (snapshot: GuardSnapshot, level: GuardLevel) {
        let processes = raw.processes.sorted { $0.rssKiB > $1.rssKiB }
        let pids = Set(processes.map(\.pid))

        var groupsByKind: [ProcessKind: [ProcessInfoSnapshot]] = [:]
        for process in processes {
            groupsByKind[process.kind, default: []].append(process)
        }

        let groups = ProcessKind.displayOrder.compactMap { kind -> ProcessGroup? in
            guard let items = groupsByKind[kind], !items.isEmpty else { return nil }
            return ProcessGroup(
                name: kind.title,
                processCount: items.count,
                totalRSSKiB: items.reduce(0) { $0 + $1.rssKiB }
            )
        }.sorted { $0.totalRSSKiB > $1.totalRSSKiB }

        let staleRaw = processes.filter { process in
            guard process.kind == .browserAutomation else { return false }
            guard process.ageSeconds >= GuardSettings.staleAutomationSeconds else { return false }
            guard process.cpuPercent <= 2.0 else { return false }
            guard process.pid != raw.frontmostPID else { return false }

            let parentMissing = process.ppid <= 1 || !pids.contains(process.ppid)
            let veryOld = process.ageSeconds >= GuardSettings.staleAutomationSeconds * 2
            return parentMissing || veryOld
        }

        var activeStalePids = Set<Int32>()
        for process in staleRaw {
            staleObservationCounts[process.pid, default: 0] += 1
            activeStalePids.insert(process.pid)
        }
        staleObservationCounts = staleObservationCounts.filter { activeStalePids.contains($0.key) }

        let staleBrowserProcesses = staleRaw
            .filter { staleObservationCounts[$0.pid, default: 0] >= 2 }
            .sorted { $0.rssKiB > $1.rssKiB }

        var reasons: [String] = []
        var computedLevel = GuardLevel.ok
        let dockerGroup = groups.first { $0.name == ProcessKind.docker.title }
        let codexGroup = groups.first { $0.name == ProcessKind.codex.title }
        let devGroup = groups.first { $0.name == ProcessKind.dev.title }

        if raw.freePercent <= GuardSettings.criticalFreePercent {
            computedLevel = .critical
            reasons.append("Free memory is critically low at \(raw.freePercent)%.")
        } else if raw.freePercent <= GuardSettings.warningFreePercent {
            computedLevel = max(computedLevel, .warning)
            reasons.append("Free memory is low at \(raw.freePercent)%.")
        }

        if raw.swapGiB >= GuardSettings.criticalSwapGiB {
            computedLevel = .critical
            reasons.append("Swap is critical at \(raw.swapGiB.formattedGiB).")
        } else if raw.swapGiB >= GuardSettings.warningSwapGiB {
            computedLevel = max(computedLevel, .warning)
            reasons.append("Swap is high at \(raw.swapGiB.formattedGiB).")
        }

        if raw.compressorGiB >= GuardSettings.criticalCompressorGiB {
            computedLevel = .critical
            reasons.append("Compressor is critical at \(raw.compressorGiB.formattedGiB).")
        } else if raw.compressorGiB >= GuardSettings.warningCompressorGiB {
            computedLevel = max(computedLevel, .warning)
            reasons.append("Compressor is high at \(raw.compressorGiB.formattedGiB).")
        }

        if let trend = trendSignal(current: raw) {
            computedLevel = max(computedLevel, trend.level)
            reasons.append(trend.message)
        }

        if staleBrowserProcesses.count >= 3 {
            computedLevel = max(computedLevel, .warning)
            reasons.append("\(staleBrowserProcesses.count) stale browser automation processes detected.")
        }

        if let codexGroup, codexGroup.processCount >= 50 || codexGroup.totalRSSGiB >= 8 {
            computedLevel = max(computedLevel, .warning)
            reasons.append("Codex/MCP helpers are high: \(codexGroup.processCount) processes, \(codexGroup.totalRSSGiB.formattedGiB).")
        }

        if let devGroup, devGroup.totalRSSGiB >= 18 {
            computedLevel = max(computedLevel, .warning)
            reasons.append("Node/dev processes are high at \(devGroup.totalRSSGiB.formattedGiB).")
        }

        if let top = processes.first, top.rssGiB >= 6 {
            computedLevel = max(computedLevel, .warning)
            reasons.append("\(top.shortName) is using \(top.rssGiB.formattedGiB).")
        }

        let combinedDevPressure = (dockerGroup?.totalRSSGiB ?? 0)
            + (codexGroup?.totalRSSGiB ?? 0)
            + (devGroup?.totalRSSGiB ?? 0)
        if raw.freePercent <= 25 && raw.compressorGiB >= 8 && combinedDevPressure >= 25 {
            computedLevel = max(computedLevel, .critical)
            reasons.append("This resembles the May 5 crash pattern: low free memory, high compressor, and large Docker/Codex/dev groups.")
        }

        let snapshot = GuardSnapshot(
            checkedAt: Date(),
            freePercent: raw.freePercent,
            compressorGiB: raw.compressorGiB,
            swapGiB: raw.swapGiB,
            swapfileCount: raw.swapfileCount,
            uptimeSummary: raw.uptimeSummary,
            topProcesses: Array(processes.prefix(12)),
            groups: groups,
            staleBrowserProcesses: staleBrowserProcesses,
            reasons: reasons
        )

        return (snapshot, computedLevel)
    }

    private func appendHistory(snapshot: GuardSnapshot, level: GuardLevel) {
        history.append(HistorySample(
            checkedAt: snapshot.checkedAt,
            freePercent: snapshot.freePercent,
            compressorGiB: snapshot.compressorGiB,
            swapGiB: snapshot.swapGiB,
            level: level
        ))

        if history.count > 120 {
            history.removeFirst(history.count - 120)
        }

        if level != .ok {
            EventLogger.log("level=\(level.title) free=\(snapshot.freePercent) compressor=\(snapshot.compressorGiB.formattedGiB) swap=\(snapshot.swapGiB.formattedGiB) reasons=\(snapshot.reasons)")
        }
    }

    private func trendSignal(current: RawSnapshot) -> TrendSignal? {
        let cutoff = Date().addingTimeInterval(-TimeInterval(GuardSettings.trendWindowMinutes * 60))
        let candidates = history.filter { $0.checkedAt >= cutoff }
        guard let baseline = candidates.first ?? history.last else {
            return nil
        }

        let elapsed = Date().timeIntervalSince(baseline.checkedAt)
        guard elapsed >= 120 else {
            return nil
        }

        let compressorDelta = current.compressorGiB - baseline.compressorGiB
        let swapDelta = current.swapGiB - baseline.swapGiB
        var messages: [String] = []

        if compressorDelta >= GuardSettings.warningCompressorTrendGiB {
            messages.append("Compressor rose \(compressorDelta.formattedGiB) in ~\(Int(elapsed / 60)) min.")
        }

        if swapDelta >= GuardSettings.warningSwapTrendGiB {
            messages.append("Swap rose \(swapDelta.formattedGiB) in ~\(Int(elapsed / 60)) min.")
        }

        guard !messages.isEmpty else {
            return nil
        }

        return TrendSignal(level: .warning, message: messages.joined(separator: " "))
    }

    private func notifyIfNeeded(snapshot: GuardSnapshot, level: GuardLevel) {
        switch level {
        case .critical:
            sendNotification(
                key: "critical-pressure",
                title: "System Guard: critical pressure",
                body: snapshot.reasons.first ?? "Memory pressure is critical.",
                minimumGap: 900
            )
        case .warning:
            sendNotification(
                key: "warning-pressure",
                title: "System Guard: memory warning",
                body: snapshot.reasons.first ?? "Memory pressure is rising.",
                minimumGap: 1800
            )
        case .ok:
            break
        }

        if snapshot.staleBrowserProcesses.count >= 3 {
            sendNotification(
                key: "stale-browser-automation",
                title: "System Guard: stale browser automation",
                body: "\(snapshot.staleBrowserProcesses.count) stale browser automation processes are safe cleanup candidates.",
                minimumGap: 1800
            )
        }
    }

    private func sendNotification(key: String, title: String, body: String, minimumGap: TimeInterval) {
        let now = Date()
        if let last = lastNotificationAt[key], now.timeIntervalSince(last) < minimumGap {
            return
        }
        lastNotificationAt[key] = now

        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        content.sound = .default

        let request = UNNotificationRequest(identifier: "\(key)-\(Int(now.timeIntervalSince1970))", content: content, trigger: nil)
        UNUserNotificationCenter.current().add(request)
    }

    private func refreshNotificationStatus() {
        UNUserNotificationCenter.current().getNotificationSettings { [weak self] settings in
            let text: String
            switch settings.authorizationStatus {
            case .authorized:
                text = "Allowed"
            case .provisional:
                text = "Provisional"
            case .ephemeral:
                text = "Ephemeral"
            case .denied:
                text = "Denied"
            case .notDetermined:
                text = "Not requested"
            @unknown default:
                text = "Unknown"
            }

            Task { @MainActor in
                self?.notificationStatusText = text
            }
        }
    }

    private func refreshLoginItemStatus() {
        loginItemStatusText = LoginItemSupport.statusText()
    }
}

enum GuardLevel: Comparable {
    case ok
    case warning
    case critical

    var title: String {
        switch self {
        case .ok:
            return "System OK"
        case .warning:
            return "Memory Warning"
        case .critical:
            return "Critical Pressure"
        }
    }

    var symbolName: String {
        switch self {
        case .ok:
            return "checkmark.circle.fill"
        case .warning:
            return "exclamationmark.triangle.fill"
        case .critical:
            return "xmark.octagon.fill"
        }
    }

    var color: Color {
        switch self {
        case .ok:
            return .green
        case .warning:
            return .orange
        case .critical:
            return .red
        }
    }
}

struct GuardSnapshot {
    var checkedAt: Date
    var freePercent: Int
    var compressorGiB: Double
    var swapGiB: Double
    var swapfileCount: Int
    var uptimeSummary: String
    var topProcesses: [ProcessInfoSnapshot]
    var groups: [ProcessGroup]
    var staleBrowserProcesses: [ProcessInfoSnapshot]
    var reasons: [String]

    static let empty = GuardSnapshot(
        checkedAt: .distantPast,
        freePercent: -1,
        compressorGiB: 0,
        swapGiB: 0,
        swapfileCount: 0,
        uptimeSummary: "unknown",
        topProcesses: [],
        groups: [],
        staleBrowserProcesses: [],
        reasons: []
    )

    var isPlaceholder: Bool {
        checkedAt == .distantPast || freePercent < 0
    }

    var checkedAtText: String {
        isPlaceholder ? "Checking now..." : "Last checked \(checkedAt.formatted(date: .omitted, time: .standard))"
    }

    var freePercentText: String {
        isPlaceholder ? "Checking..." : "\(freePercent)%"
    }

    var pressureProgress: Double {
        guard !isPlaceholder else { return 0.08 }
        return Double(max(0, min(100, 100 - freePercent))) / 100.0
    }

    var primaryReason: String? {
        reasons.first
    }

    var headerDetailText: String {
        if isPlaceholder {
            return "Collecting pressure snapshot..."
        }
        if uptimeSummary == "unknown" {
            return checkedAtText
        }
        return "\(checkedAtText) / up \(uptimeSummary)"
    }

    var diagnosticText: String {
        var lines: [String] = []
        lines.append("System Guard Snapshot")
        lines.append("Checked: \(checkedAt)")
        lines.append("Free: \(freePercent)%")
        lines.append("Compressor: \(compressorGiB.formattedGiB)")
        lines.append("Swap: \(swapGiB.formattedGiB)")
        lines.append("Swap files: \(swapfileCount)")
        lines.append("Uptime: \(uptimeSummary)")
        lines.append("")
        lines.append("Reasons:")
        lines.append(contentsOf: reasons.map { "- \($0)" })
        lines.append("")
        lines.append("Groups:")
        lines.append(contentsOf: groups.map { "- \($0.name): \($0.totalRSSGiB.formattedGiB), \($0.processCount) processes" })
        lines.append("")
        lines.append("Stale browser automation:")
        lines.append(contentsOf: staleBrowserProcesses.map { "- \($0.pid) \($0.rssGiB.formattedGiB) \($0.elapsed) \($0.command)" })
        lines.append("")
        lines.append("Top processes:")
        lines.append(contentsOf: topProcesses.map { "- \($0.pid) \($0.rssGiB.formattedGiB) \($0.elapsed) \($0.command)" })
        return lines.joined(separator: "\n")
    }
}

struct ProcessGroup: Identifiable {
    var id: String { name }
    let name: String
    let processCount: Int
    let totalRSSKiB: Int

    var totalRSSGiB: Double {
        Double(totalRSSKiB) / 1024.0 / 1024.0
    }

    var symbolName: String {
        ProcessKind.displayOrder.first { $0.title == name }?.symbolName ?? "square.stack.3d.up"
    }

    var tint: Color {
        switch name {
        case ProcessKind.docker.title:
            return .blue
        case ProcessKind.browserAutomation.title:
            return .orange
        case ProcessKind.codex.title:
            return .purple
        case ProcessKind.dev.title:
            return .teal
        case ProcessKind.terminalEditor.title:
            return .cyan
        case ProcessKind.messaging.title:
            return .mint
        case ProcessKind.aiAgent.title:
            return .pink
        case ProcessKind.productivity.title:
            return .brown
        case ProcessKind.browser.title:
            return .indigo
        case ProcessKind.system.title:
            return .gray
        default:
            return .secondary
        }
    }
}

struct HistorySample: Identifiable {
    let id = UUID()
    let checkedAt: Date
    let freePercent: Int
    let compressorGiB: Double
    let swapGiB: Double
    let level: GuardLevel

    var barHeight: CGFloat {
        let pressure = max(0, min(100, 100 - freePercent))
        return max(5, CGFloat(pressure) / 100.0 * 42.0)
    }
}

struct ProcessInfoSnapshot: Identifiable {
    var id: Int32 { pid }
    let pid: Int32
    let ppid: Int32
    let elapsed: String
    let ageSeconds: Int
    let rssKiB: Int
    let cpuPercent: Double
    let command: String
    let kind: ProcessKind

    var rssGiB: Double {
        Double(rssKiB) / 1024.0 / 1024.0
    }

    var shortName: String {
        let trimmed = command.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.contains("com.apple.Virtualization.VirtualMachine") {
            return "Docker VM"
        }
        if trimmed.contains("SkyComputerUseClient") {
            return "SkyComputerUseClient"
        }
        if trimmed.contains("Google Chrome for Testing") {
            return "Chrome for Testing"
        }
        if trimmed.contains("chrome-headless-shell") {
            return "chrome-headless-shell"
        }
        if trimmed.contains("@openai/codex") || trimmed.contains("/bin/codex") {
            return "Codex"
        }
        return URL(fileURLWithPath: trimmed.components(separatedBy: " ").first ?? trimmed).lastPathComponent
    }

    var displaySummary: String {
        "\(shortName) \(rssGiB.formattedGiB)"
    }
}

enum StaleProcessConfirmationFormatter {
    static func line(for process: ProcessInfoSnapshot) -> String {
        "pid \(process.pid) / \(process.shortName) / \(process.rssGiB.formattedGiB) / age \(process.elapsed)"
    }

    static func lines(for processes: [ProcessInfoSnapshot]) -> String {
        processes.map(line(for:)).joined(separator: "\n")
    }
}

enum ProcessKind: String {
    case docker
    case browserAutomation
    case codex
    case dev
    case terminalEditor
    case messaging
    case aiAgent
    case productivity
    case browser
    case system
    case other

    static let displayOrder: [ProcessKind] = [
        .docker,
        .browserAutomation,
        .codex,
        .dev,
        .terminalEditor,
        .aiAgent,
        .browser,
        .messaging,
        .productivity,
        .system,
        .other
    ]

    var title: String {
        switch self {
        case .docker:
            return "Docker"
        case .browserAutomation:
            return "Browser Automation"
        case .codex:
            return "Codex / MCP"
        case .dev:
            return "Node / Dev"
        case .terminalEditor:
            return "Terminals / Editors"
        case .messaging:
            return "Messaging"
        case .aiAgent:
            return "AI / Agents"
        case .productivity:
            return "Productivity"
        case .browser:
            return "Browsers"
        case .system:
            return "System Services"
        case .other:
            return "Other"
        }
    }

    var symbolName: String {
        switch self {
        case .docker:
            return "shippingbox"
        case .browserAutomation:
            return "globe.badge.chevron.backward"
        case .codex:
            return "terminal"
        case .dev:
            return "hammer"
        case .terminalEditor:
            return "terminal"
        case .messaging:
            return "message"
        case .aiAgent:
            return "sparkles"
        case .productivity:
            return "wand.and.stars"
        case .browser:
            return "safari"
        case .system:
            return "gearshape.2"
        case .other:
            return "app"
        }
    }

    var tint: Color {
        switch self {
        case .docker:
            return .blue
        case .browserAutomation:
            return .orange
        case .codex:
            return .purple
        case .dev:
            return .teal
        case .terminalEditor:
            return .cyan
        case .messaging:
            return .mint
        case .aiAgent:
            return .pink
        case .productivity:
            return .brown
        case .browser:
            return .indigo
        case .system:
            return .gray
        case .other:
            return .secondary
        }
    }
}

struct RawSnapshot {
    let freePercent: Int
    let compressorGiB: Double
    let swapGiB: Double
    let swapfileCount: Int
    let uptimeSummary: String
    let frontmostPID: Int32?
    let processes: [ProcessInfoSnapshot]
}

struct TrendSignal {
    let level: GuardLevel
    let message: String
}

struct ParsedProcessRecord {
    let pid: Int32
    let ppid: Int32
    let elapsed: String
    let ageSeconds: Int
    let rssKiB: Int
    let cpuPercent: Double
    let command: String
}

struct AppProcessHint {
    let name: String
    let bundleIdentifier: String
    let bundlePath: String
}

enum SystemCollector {
    static func collect() -> RawSnapshot {
        let memoryPressure = Command.run("/usr/bin/memory_pressure")
        let vmStat = Command.run("/usr/bin/vm_stat")
        let du = Command.run("/usr/bin/du", arguments: ["-sk", "/private/var/vm"])
        let ps = Command.run("/bin/ps", arguments: ["-axo", "rss=,pid=,ppid=,etime=,pcpu=,command="])
        let uptime = Command.run("/usr/bin/uptime")

        return RawSnapshot(
            freePercent: parseFreePercent(memoryPressure) ?? parseAvailablePercentFromVMStat(vmStat),
            compressorGiB: parseCompressorGiB(vmStat),
            swapGiB: parseSwapGiB(du),
            swapfileCount: countSwapfiles(),
            uptimeSummary: parseUptime(uptime),
            frontmostPID: NSWorkspace.shared.frontmostApplication?.processIdentifier,
            processes: parseProcesses(ps)
        )
    }

    static func runSelfTests() {
        selfTestAssert(
            parseFreePercent("System-wide memory free percentage: 27%") == 27,
            "memory_pressure free percentage parse"
        )

        let vmStat = """
        Mach Virtual Memory Statistics: (page size of 16384 bytes)
        Pages free:                               10.
        Pages active:                             50.
        Pages inactive:                           20.
        Pages speculative:                        10.
        Pages wired down:                         50.
        Pages purgeable:                          10.
        Pages occupied by compressor:             50.
        """
        selfTestAssert(
            parseAvailablePercentFromVMStat(vmStat) == 25,
            "vm_stat available percentage fallback"
        )

        let compressor = """
        Mach Virtual Memory Statistics: (page size of 16384 bytes)
        Pages occupied by compressor:             65536.
        """
        selfTestAssert(
            abs(parseCompressorGiB(compressor) - 1.0) < 0.001,
            "vm_stat compressor GiB parse"
        )

        selfTestAssert(
            abs(parseSwapGiB("1048576\t/private/var/vm\n") - 1.0) < 0.001,
            "du swap GiB parse"
        )

        selfTestAssert(parseElapsedSeconds("01:02:03") == 3_723, "elapsed HH:MM:SS parse")
        selfTestAssert(parseElapsedSeconds("2-01:00:00") == 176_400, "elapsed D-HH:MM:SS parse")

        let ps = """
        1048576 123 1 01:02:03 0.1 /Applications/Google Chrome for Testing.app/Contents/MacOS/Google Chrome for Testing --headless
        524288 124 123 00:10 0.0 node /tmp/server.js
        262144 125 1 00:01 0.0 /System/Library/CoreServices/Finder.app/Contents/MacOS/Finder
        """
        let processes = parseProcesses(ps)
        selfTestAssert(processes.count == 3, "ps record count")
        selfTestAssert(
            processes.first { $0.pid == 123 }?.kind == .browserAutomation,
            "headless Chrome classification"
        )
        selfTestAssert(
            processes.first { $0.pid == 124 }?.kind == .dev,
            "node classification"
        )
        selfTestAssert(
            processes.first { $0.pid == 125 }?.kind == .system,
            "system app classification"
        )
        selfTestAssert(
            processes.first { $0.pid == 123 }?.ageSeconds == 3_723,
            "ps elapsed seconds propagation"
        )
        selfTestAssert(
            StaleProcessConfirmationFormatter.line(for: processes[0]) == "pid 123 / Chrome for Testing / 1.0 GiB / age 01:02:03",
            "stale confirmation process detail line"
        )
    }

    private static func selfTestAssert(_ condition: @autoclosure () -> Bool, _ message: String) {
        if !condition() {
            FileHandle.standardError.write(Data("self-test failed: \(message)\n".utf8))
            Foundation.exit(1)
        }
    }

    private static func parseFreePercent(_ output: String) -> Int? {
        for line in output.components(separatedBy: .newlines) {
            if line.contains("System-wide memory free percentage") {
                let digits = line.compactMap { $0.isNumber ? String($0) : nil }.joined()
                return Int(digits)
            }
        }
        return nil
    }

    private static func parseAvailablePercentFromVMStat(_ output: String) -> Int {
        var pageCounts: [String: Int] = [:]
        for line in output.components(separatedBy: .newlines) {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            guard let keyEnd = trimmed.firstIndex(of: ":") else { continue }
            let key = String(trimmed[..<keyEnd])
            let value = parseFirstInteger(String(trimmed[trimmed.index(after: keyEnd)...]))
            pageCounts[key] = value
        }

        let free = pageCounts["Pages free"] ?? 0
        let inactive = pageCounts["Pages inactive"] ?? 0
        let speculative = pageCounts["Pages speculative"] ?? 0
        let purgeable = pageCounts["Pages purgeable"] ?? 0
        let active = pageCounts["Pages active"] ?? 0
        let wired = pageCounts["Pages wired down"] ?? 0
        let compressor = pageCounts["Pages occupied by compressor"] ?? 0

        let available = free + inactive + speculative + purgeable
        let total = available + active + wired + compressor
        guard total > 0 else { return 0 }
        return Int((Double(available) / Double(total) * 100.0).rounded())
    }

    private static func parseCompressorGiB(_ output: String) -> Double {
        let pageSize = parsePageSize(output)
        var storedPages: Int?
        for line in output.components(separatedBy: .newlines) {
            if line.hasPrefix("Pages occupied by compressor:") {
                let pages = parseFirstInteger(line)
                return Double(pages * pageSize) / 1024.0 / 1024.0 / 1024.0
            }
            if line.hasPrefix("Pages stored in compressor:") {
                storedPages = parseFirstInteger(line)
            }
        }
        if let storedPages {
            return Double(storedPages * pageSize) / 1024.0 / 1024.0 / 1024.0
        }
        return 0
    }

    private static func parsePageSize(_ output: String) -> Int {
        for line in output.components(separatedBy: .newlines) {
            if line.contains("page size of") {
                return parseFirstInteger(line)
            }
        }
        return 16_384
    }

    private static func parseFirstInteger(_ line: String) -> Int {
        let normalized = line.replacingOccurrences(of: ".", with: "")
        let parts = normalized.split { !$0.isNumber }
        return parts.compactMap { Int($0) }.first ?? 0
    }

    private static func parseSwapGiB(_ output: String) -> Double {
        let first = output.split(whereSeparator: \.isWhitespace).first
        let kb = Double(first ?? "0") ?? 0
        return kb / 1024.0 / 1024.0
    }

    private static func countSwapfiles() -> Int {
        let path = "/private/var/vm"
        let files = (try? FileManager.default.contentsOfDirectory(atPath: path)) ?? []
        return files.filter { $0.hasPrefix("swapfile") }.count
    }

    private static func parseUptime(_ output: String) -> String {
        guard let upRange = output.range(of: " up ") else {
            return "unknown"
        }
        let afterUp = output[upRange.upperBound...]
        if let usersRange = afterUp.range(of: ",  ") {
            return String(afterUp[..<usersRange.lowerBound]).trimmingCharacters(in: .whitespaces)
        }
        return String(afterUp).trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func parseProcesses(_ output: String) -> [ProcessInfoSnapshot] {
        let records = output.components(separatedBy: .newlines).compactMap { line -> ParsedProcessRecord? in
            let parts = line.split(maxSplits: 5, omittingEmptySubsequences: true, whereSeparator: \.isWhitespace)
            guard parts.count == 6,
                  let rss = Int(parts[0]),
                  let pid = Int32(parts[1]),
                  let ppid = Int32(parts[2]),
                  let cpu = Double(parts[4])
            else {
                return nil
            }

            let elapsed = String(parts[3])
            let command = String(parts[5])
            return ParsedProcessRecord(
                pid: pid,
                ppid: ppid,
                elapsed: elapsed,
                ageSeconds: parseElapsedSeconds(elapsed),
                rssKiB: rss,
                cpuPercent: cpu,
                command: command
            )
        }

        let parentByPID = Dictionary(uniqueKeysWithValues: records.map { ($0.pid, $0.ppid) })
        let appHints = runningAppHints()

        return records.map { record in
            let owner = owningAppHint(for: record.pid, parentByPID: parentByPID, appHints: appHints)
            return ProcessInfoSnapshot(
                pid: record.pid,
                ppid: record.ppid,
                elapsed: record.elapsed,
                ageSeconds: record.ageSeconds,
                rssKiB: record.rssKiB,
                cpuPercent: record.cpuPercent,
                command: record.command,
                kind: classify(command: record.command, owner: owner)
            )
        }
    }

    private static func parseElapsedSeconds(_ value: String) -> Int {
        let daySplit = value.split(separator: "-", maxSplits: 1).map(String.init)
        let days: Int
        let timePart: String
        if daySplit.count == 2 {
            days = Int(daySplit[0]) ?? 0
            timePart = daySplit[1]
        } else {
            days = 0
            timePart = value
        }

        let pieces = timePart.split(separator: ":").compactMap { Int($0) }
        var seconds = days * 86_400
        if pieces.count == 3 {
            seconds += pieces[0] * 3_600 + pieces[1] * 60 + pieces[2]
        } else if pieces.count == 2 {
            seconds += pieces[0] * 60 + pieces[1]
        } else if pieces.count == 1 {
            seconds += pieces[0]
        }
        return seconds
    }

    private static func runningAppHints() -> [Int32: AppProcessHint] {
        var hints: [Int32: AppProcessHint] = [:]
        for app in NSWorkspace.shared.runningApplications {
            let pid = app.processIdentifier
            guard pid > 0 else { continue }
            hints[pid] = AppProcessHint(
                name: app.localizedName ?? "",
                bundleIdentifier: app.bundleIdentifier ?? "",
                bundlePath: app.bundleURL?.path ?? ""
            )
        }
        return hints
    }

    private static func owningAppHint(
        for pid: Int32,
        parentByPID: [Int32: Int32],
        appHints: [Int32: AppProcessHint]
    ) -> AppProcessHint? {
        var current = pid
        var seen = Set<Int32>()

        for _ in 0..<12 {
            if let hint = appHints[current] {
                return hint
            }
            guard let parent = parentByPID[current], parent > 1, !seen.contains(parent) else {
                return nil
            }
            seen.insert(current)
            current = parent
        }

        return nil
    }

    private static func classify(command: String, owner: AppProcessHint?) -> ProcessKind {
        let lower = command.lowercased()
        let ownerText = [
            owner?.name,
            owner?.bundleIdentifier,
            owner?.bundlePath
        ]
            .compactMap { $0 }
            .joined(separator: " ")
            .lowercased()
        let combined = "\(lower) \(ownerText)"

        if combined.contains("com.apple.virtualization.virtualmachine")
            || combined.contains("docker.app")
            || combined.contains("com.docker")
            || combined.contains("docker desktop") {
            return .docker
        }

        if command.contains("Google Chrome for Testing")
            || combined.contains("chrome-headless-shell")
            || combined.contains("chromedriver")
            || combined.contains("playwright")
            || (combined.contains("--headless") && (combined.contains("chrome") || combined.contains("chromium")))
            || (combined.contains("--remote-debugging-port") && (combined.contains("chrome") || combined.contains("chromium"))) {
            return .browserAutomation
        }

        if combined.contains("@openai/codex")
            || combined.contains("/bin/codex")
            || combined.contains(" codex ")
            || combined.contains("skycomputeruseclient")
            || combined.contains("codex computer use")
            || combined.contains("expect-cli@latest mcp")
            || combined.contains("/expect-cli/")
            || combined.contains("browser-mcp.js")
            || combined.contains("mcp-server") {
            return .codex
        }

        if combined.contains("/node ")
            || combined.hasSuffix("/node")
            || combined.hasPrefix("node ")
            || combined.contains(" node ")
            || combined.contains("/bun ")
            || combined.hasSuffix("/bun")
            || combined.hasPrefix("bun ")
            || combined.contains(" bun ")
            || combined.contains("/python")
            || combined.hasPrefix("python")
            || combined.contains(" python")
            || combined.contains(" pnpm ")
            || combined.hasPrefix("pnpm ")
            || combined.contains(" npm ")
            || combined.hasPrefix("npm ")
            || combined.contains(" tilt ")
            || combined.hasPrefix("tilt ") {
            return .dev
        }

        if combined.contains("safari.app")
            || combined.contains("com.apple.safari")
            || combined.contains("webkit")
            || combined.contains("microsoft edge")
            || combined.contains("com.microsoft.edgemac")
            || combined.contains("google chrome.app")
            || combined.contains("com.google.chrome")
            || combined.contains("firefox.app")
            || combined.contains("org.mozilla.firefox") {
            return .browser
        }

        if combined.contains("/applications/ghostty.app")
            || combined.contains("/applications/zed.app")
            || combined.contains("/applications/visual studio code.app")
            || combined.contains("/applications/cursor.app")
            || combined.contains("/applications/terminal.app")
            || combined.contains("/applications/iterm.app")
            || combined.contains("/applications/iterm2.app")
            || combined.contains("/applications/xcode.app") {
            return .terminalEditor
        }

        if combined.contains("/applications/telegram.app")
            || combined.contains("ru.keepcoder.telegram")
            || combined.contains("/applications/whatsapp.app")
            || combined.contains("whatsapp")
            || combined.contains("/applications/slack.app")
            || combined.contains("com.tinyspeck.slackmacgap")
            || combined.contains("/applications/discord.app")
            || combined.contains("com.hnc.discord")
            || combined.contains("/applications/messages.app")
            || combined.contains("com.apple.messages") {
            return .messaging
        }

        if combined.contains("/applications/ollama.app")
            || combined.contains("/ollama serve")
            || combined.contains("/.hermes/")
            || combined.contains("/hermes ")
            || combined.contains("agentcash")
            || combined.contains("claude")
            || combined.contains("gemini") {
            return .aiAgent
        }

        if combined.contains("/applications/raycast.app")
            || combined.contains("com.raycast.macos")
            || combined.contains("raycast helper")
            || combined.contains("/applications/linear.app")
            || combined.contains("/applications/notion.app")
            || combined.contains("/applications/numbers.app")
            || combined.contains("/applications/music.app")
            || combined.contains("/applications/calendar.app")
            || combined.contains("/applications/activity monitor.app")
            || combined.contains("system guard.app") {
            return .productivity
        }

        if combined.contains("/applications/") {
            return .productivity
        }

        if combined.hasPrefix("/system/")
            || combined.hasPrefix("/usr/libexec/")
            || combined.hasPrefix("/usr/sbin/")
            || combined.hasPrefix("/sbin/")
            || combined.hasPrefix("/bin/")
            || combined.contains("mtlcompilerservice")
            || combined.contains("themewidgetcontrolviewservice")
            || combined.contains("imageioxpcservice")
            || combined.contains("localauthenticationremoteservice")
            || combined.contains("quicklookuiservice")
            || combined.contains("appleeventsd")
            || combined.contains("cfprefsd")
            || combined.contains("com.apple.") {
            return .system
        }

        return .other
    }
}

enum Command {
    static func run(_ executable: String, arguments: [String] = []) -> String {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments

        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe

        do {
            try process.run()
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            process.waitUntilExit()
            return String(decoding: data, as: UTF8.self)
        } catch {
            return ""
        }
    }
}

enum EventLogger {
    static func log(_ message: String) {
        let directory = URL(fileURLWithPath: NSHomeDirectory())
            .appendingPathComponent("Library/Logs/SystemGuard", isDirectory: true)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)

        let line = "\(ISO8601DateFormatter().string(from: Date())) \(message)\n"
        let file = directory.appendingPathComponent("systemguard.log")

        if FileManager.default.fileExists(atPath: file.path),
           let handle = try? FileHandle(forWritingTo: file) {
            defer { try? handle.close() }
            _ = try? handle.seekToEnd()
            if let data = line.data(using: .utf8) {
                try? handle.write(contentsOf: data)
            }
        } else {
            try? line.write(to: file, atomically: true, encoding: .utf8)
        }
    }
}

enum DiagnosticFormatter {
    static func rawSnapshotText(_ snapshot: RawSnapshot) -> String {
        let groups = Dictionary(grouping: snapshot.processes, by: \.kind)
            .map { kind, processes in
                ProcessGroup(
                    name: kind.title,
                    processCount: processes.count,
                    totalRSSKiB: processes.reduce(0) { $0 + $1.rssKiB }
                )
            }
            .sorted { $0.totalRSSKiB > $1.totalRSSKiB }

        var lines: [String] = []
        lines.append("System Guard Snapshot")
        lines.append("freePercent=\(snapshot.freePercent)")
        lines.append("compressor=\(snapshot.compressorGiB.formattedGiB)")
        lines.append("swap=\(snapshot.swapGiB.formattedGiB)")
        lines.append("swapfileCount=\(snapshot.swapfileCount)")
        lines.append("uptime=\(snapshot.uptimeSummary)")
        lines.append("frontmostPID=\(snapshot.frontmostPID.map(String.init) ?? "unknown")")
        lines.append("")
        lines.append("groups:")
        lines.append(contentsOf: groups.map { "\($0.name): \($0.totalRSSGiB.formattedGiB), \($0.processCount) processes" })
        lines.append("")
        lines.append("topProcesses:")
        lines.append(contentsOf: snapshot.processes.sorted { $0.rssKiB > $1.rssKiB }.prefix(12).map {
            "\($0.pid) \($0.rssGiB.formattedGiB) \($0.kind.title) \($0.shortName)"
        })
        return lines.joined(separator: "\n")
    }
}

enum GuardSettings {
    static var warningSwapGiB: Double {
        defaultedDouble("warningSwapGiB", 6)
    }

    static var criticalSwapGiB: Double {
        defaultedDouble("criticalSwapGiB", 10)
    }

    static var warningCompressorGiB: Double {
        defaultedDouble("warningCompressorGiB", 10)
    }

    static var criticalCompressorGiB: Double {
        defaultedDouble("criticalCompressorGiB", 16)
    }

    static var trendWindowMinutes: Int {
        max(3, defaultedInt("trendWindowMinutes", 10))
    }

    static var warningCompressorTrendGiB: Double {
        defaultedDouble("warningCompressorTrendGiB", 2)
    }

    static var warningSwapTrendGiB: Double {
        defaultedDouble("warningSwapTrendGiB", 1)
    }

    static var warningFreePercent: Int {
        defaultedInt("warningFreePercent", 25)
    }

    static var criticalFreePercent: Int {
        defaultedInt("criticalFreePercent", 10)
    }

    static var staleAutomationSeconds: Int {
        max(60, defaultedInt("staleAutomationMinutes", 45) * 60)
    }

    static var pollSeconds: Int {
        max(15, defaultedInt("pollSeconds", 45))
    }

    private static func defaultedDouble(_ key: String, _ fallback: Double) -> Double {
        let value = UserDefaults.standard.double(forKey: key)
        return value > 0 ? value : fallback
    }

    private static func defaultedInt(_ key: String, _ fallback: Int) -> Int {
        let value = UserDefaults.standard.integer(forKey: key)
        return value > 0 ? value : fallback
    }
}

extension Double {
    var formattedGiB: String {
        if self >= 10 {
            return String(format: "%.0f GiB", self)
        }
        if self >= 1 {
            return String(format: "%.1f GiB", self)
        }
        return String(format: "%.0f MiB", self * 1024)
    }
}
