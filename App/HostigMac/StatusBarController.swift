import SwiftUI
import AppKit
import HostigLocalServices
import HostigModels
import Combine

@MainActor
final class MainWindowBridge: NSObject, ObservableObject, NSWindowDelegate {
    weak var window: NSWindow?

    func attach(window: NSWindow) {
        guard self.window !== window else { return }
        self.window = window
        window.delegate = self
    }

    func showMainWindow() {
        guard let window else { return }
        NSApplication.shared.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
    }

    func windowShouldClose(_ sender: NSWindow) -> Bool {
        sender.orderOut(nil)
        return false
    }
}

struct WindowAccessor: NSViewRepresentable {
    @ObservedObject var mainWindowBridge: MainWindowBridge

    func makeNSView(context: Context) -> NSView {
        let view = NSView()
        DispatchQueue.main.async {
            if let window = view.window {
                mainWindowBridge.attach(window: window)
            }
        }
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        DispatchQueue.main.async {
            if let window = nsView.window {
                mainWindowBridge.attach(window: window)
            }
        }
    }
}

@MainActor
final class StatusBarController: NSObject {
    private let statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
    private let panel = StatusBarPanel()
    private var hostingView: NSHostingView<StatusPanelContent>?
    private weak var mainWindowBridge: MainWindowBridge?
    private weak var statusButton: NSStatusBarButton?
    private var configured = false
    private var isPanelPresented = false
    private var localMonitor: Any?
    private var globalMonitor: Any?
    private var graphSubscription: AnyCancellable?

    func configureIfNeeded(store: HostStore, mainWindowBridge: MainWindowBridge) {
        guard !configured else { return }
        configured = true
        self.mainWindowBridge = mainWindowBridge

        if let button = statusItem.button {
            statusButton = button
            button.image = NSImage(systemSymbolName: "server.rack", accessibilityDescription: "Hostig")
            button.target = self
            button.action = #selector(handleStatusItemClick(_:))
            button.sendAction(on: [.leftMouseUp, .rightMouseUp])
        }

        graphSubscription = Publishers.Merge3(
            store.$hosts.map { _ in () },
            store.$latencyHistory.map { _ in () },
            store.$menuBarGraphHostKeys.map { _ in () }
        )
        .sink { [weak self, weak store] _ in
            DispatchQueue.main.async {
                guard let self, let store else { return }
                self.updateStatusItemGraph(from: store)
            }
        }
        updateStatusItemGraph(from: store)

        let content = StatusPanelContent(
            store: store,
            openMainWindow: { [weak self] in
                self?.panel.orderOut(nil)
                self?.mainWindowBridge?.showMainWindow()
            }
        )

        let hostingView = NSHostingView(rootView: content)
        hostingView.frame = NSRect(x: 0, y: 0, width: 360, height: 420)
        panel.contentView = hostingView
        self.hostingView = hostingView

        localMonitor = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak self] event in
            guard let self else { return event }
            guard self.isPanelPresented else { return event }
            if let panelWindow = event.window, panelWindow == self.panel {
                return event
            }
            if self.isClickOnStatusItem(event) {
                return event
            }

            self.closePanel()
            return event
        }

        globalMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak self] _ in
            guard let self, self.isPanelPresented else { return }
            if self.isCurrentMouseOnStatusItem() {
                return
            }
            self.closePanel()
        }
    }

    private func updateStatusItemGraph(from store: HostStore) {
        guard let button = statusItem.button else { return }
        var graphs: [(String, [PingHistoryPoint])] = []
        if store.showsMenuBarGraph(for: HostStore.latencyMonitorGraphKey) {
            graphs.append((store.latencyMonitorHost, store.latencyHistory))
        }
        for host in store.hosts where store.showsMenuBarGraph(for: HostStore.menuBarGraphKey(for: host)) {
            graphs.append((host.displayName, host.pingHistory))
        }

        guard !graphs.isEmpty else {
            statusItem.length = NSStatusItem.variableLength
            button.image = NSImage(systemSymbolName: "server.rack", accessibilityDescription: "Hostig")
            button.toolTip = "Hostig"
            return
        }

        let graphWidth: CGFloat = 102
        let height: CGFloat = 20
        let labelFont = NSFont.systemFont(ofSize: 10, weight: .medium)
        let labelAttributes: [NSAttributedString.Key: Any] = [
            .font: labelFont,
            .foregroundColor: NSColor.labelColor
        ]
        let entries = graphs.map { name, history in
            (name: String(name.prefix(14)), history: history)
        }
        let widths = entries.map { ($0.name as NSString).size(withAttributes: labelAttributes).width + graphWidth + 14 }
        let width = widths.reduce(0, +) + 8
        let image = NSImage(size: NSSize(width: width, height: height), flipped: false) { _ in
            var x: CGFloat = 4
            for (index, entry) in entries.enumerated() {
                let labelWidth = (entry.name as NSString).size(withAttributes: labelAttributes).width
                (entry.name as NSString).draw(at: NSPoint(x: x, y: 4), withAttributes: labelAttributes)
                x += labelWidth + 5
                Self.drawSparkline(entry.history, in: NSRect(x: x, y: 1, width: graphWidth, height: 18))
                x += graphWidth + 9
                if index < entries.count - 1 {
                    NSColor.separatorColor.setStroke()
                    let separator = NSBezierPath()
                    separator.move(to: NSPoint(x: x - 5, y: 3))
                    separator.line(to: NSPoint(x: x - 5, y: 17))
                    separator.stroke()
                }
            }
            return true
        }
        image.isTemplate = false
        statusItem.length = width
        button.image = image
        button.toolTip = graphs.map(\.0).joined(separator: " · ")
    }

    private static func drawSparkline(_ history: [PingHistoryPoint], in rect: NSRect) {
        let points = Array(history.suffix(60))
        let values = points.compactMap(\.latencyMS).filter { $0.isFinite && $0 >= 0 }
        guard let minimum = values.min(), let observedMaximum = values.max() else { return }
        let maximum = max(observedMaximum, 1)
        let path = NSBezierPath()
        path.lineWidth = 1.5
        var started = false
        for (index, point) in points.enumerated() {
            guard let latency = point.latencyMS, latency.isFinite, latency >= 0 else {
                started = false
                continue
            }
            let x = rect.minX + rect.width * CGFloat(index) / CGFloat(max(points.count - 1, 1))
            let y = rect.minY + rect.height * CGFloat(max(0, min(latency / maximum, 1)))
            let location = NSPoint(x: x, y: y)
            if started { path.line(to: location) }
            else { path.move(to: location); started = true }
        }
        NSColor.systemTeal.setStroke()
        path.stroke()

        drawGraphValue("max \(formatGraphValue(observedMaximum))", atTop: true, in: rect)
        drawGraphValue("min \(formatGraphValue(minimum))", atTop: false, in: rect)
    }

    private static func formatGraphValue(_ milliseconds: Double) -> String {
        milliseconds < 10
            ? String(format: "%.1fms", milliseconds)
            : String(format: "%.0fms", milliseconds)
    }

    private static func drawGraphValue(_ value: String, atTop: Bool, in rect: NSRect) {
        let attributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.monospacedDigitSystemFont(ofSize: 8, weight: .medium),
            .foregroundColor: NSColor.labelColor
        ]
        let text = value as NSString
        let size = text.size(withAttributes: attributes)
        let labelRect = NSRect(
            x: rect.maxX - size.width - 4,
            y: atTop ? rect.maxY - 9 : rect.minY,
            width: size.width + 4,
            height: 9
        )
        NSColor.controlBackgroundColor.withAlphaComponent(0.88).setFill()
        NSBezierPath(roundedRect: labelRect, xRadius: 2, yRadius: 2).fill()
        text.draw(at: NSPoint(x: labelRect.minX + 2, y: labelRect.minY), withAttributes: attributes)
    }

    private func openPanel() {
        guard !isPanelPresented, let button = statusItem.button else { return }
        if let hostingView {
            hostingView.rootView.panelRefreshID = UUID()
        }

        positionPanel(relativeTo: button)
        NSApplication.shared.activate(ignoringOtherApps: true)
        panel.makeKeyAndOrderFront(nil)
        isPanelPresented = true
    }

    private func closePanel() {
        guard isPanelPresented else { return }
        panel.orderOut(nil)
        isPanelPresented = false
    }

    @objc private func handleStatusItemClick(_ sender: Any?) {
        if isPanelPresented {
            closePanel()
        } else {
            openPanel()
        }
    }

    private func positionPanel(relativeTo button: NSStatusBarButton) {
        guard let buttonWindow = button.window else { return }
        let buttonFrame = button.convert(button.bounds, to: nil)
        let screenFrame = buttonWindow.convertToScreen(buttonFrame)
        let panelSize = panel.frame.size

        let origin = NSPoint(
            x: screenFrame.maxX - panelSize.width,
            y: screenFrame.minY - panelSize.height - 8
        )
        panel.setFrame(NSRect(origin: origin, size: panelSize), display: true)
    }

    private func isClickOnStatusItem(_ event: NSEvent) -> Bool {
        guard let button = statusButton, let buttonWindow = button.window else { return false }
        guard event.window == buttonWindow else { return false }
        let point = button.convert(event.locationInWindow, from: nil)
        return button.bounds.contains(point)
    }

    private func isCurrentMouseOnStatusItem() -> Bool {
        guard let button = statusButton, let buttonWindow = button.window else { return false }
        let buttonFrame = button.convert(button.bounds, to: nil)
        let screenFrame = buttonWindow.convertToScreen(buttonFrame)
        return screenFrame.contains(NSEvent.mouseLocation)
    }
}

final class StatusBarPanel: NSPanel {
    init() {
        super.init(
            contentRect: NSRect(x: 0, y: 0, width: 360, height: 420),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        isFloatingPanel = true
        level = .statusBar
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient]
        backgroundColor = .clear
        isOpaque = false
        hasShadow = true
        hidesOnDeactivate = true
        animationBehavior = .utilityWindow
    }

    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
}

private struct StatusPanelContent: View {
    @Environment(\.colorScheme) private var colorScheme
    @ObservedObject var store: HostStore
    let openMainWindow: () -> Void
    var panelRefreshID = UUID()

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                Text("Hostig")
                    .font(.system(size: 18, weight: .semibold, design: .rounded))
                Spacer()
                Button("Open") {
                    openMainWindow()
                }
                .buttonStyle(.borderless)
            }

            CompactLatencyPanel(
                host: store.latencyMonitorHost,
                snapshot: store.latencyMonitorSnapshot,
                history: store.latencyHistory
            )

            HStack(spacing: 10) {
                CapsuleMetric(title: "Hosts", value: "\(store.hosts.count)")
                CapsuleMetric(title: "SSH", value: "\(store.hosts.filter(\.hasAuthenticatedSSH).count)")
                CapsuleMetric(title: "Down", value: "\(store.hosts.filter { !$0.hasAuthenticatedSSH }.count)")
            }

            Divider().overlay(.white.opacity(0.15))

            ScrollView {
                LazyVStack(spacing: 10) {
                    ForEach(store.hosts) { host in
                        StatusHostRow(host: host)
                    }
                }
            }
        }
        .padding(18)
        .frame(width: 360, height: 420, alignment: .topLeading)
        .background(
            RoundedRectangle(cornerRadius: 24, style: .continuous)
                .fill(panelFillStyle)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 24, style: .continuous)
                .strokeBorder(colorScheme == .dark ? .white.opacity(0.14) : .white.opacity(0.22), lineWidth: 1)
        )
        .id(panelRefreshID)
    }

    private var panelFillStyle: AnyShapeStyle {
        if colorScheme == .dark {
            return AnyShapeStyle(.regularMaterial.opacity(0.95))
        }
        return AnyShapeStyle(.ultraThinMaterial.opacity(0.92))
    }
}

private struct CompactLatencyPanel: View {
    @Environment(\.colorScheme) private var colorScheme
    let host: String
    let snapshot: PingSnapshot?
    let history: [PingHistoryPoint]

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Ping")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Text(host)
                        .font(.caption.monospaced())
                        .lineLimit(1)
                }
                Spacer()
                Text(snapshot?.latencyMS.map { String(format: "%.1f ms", $0) } ?? "n/a")
                    .font(.headline.monospacedDigit())
            }

            MiniLatencyGraph(history: history)
                .frame(height: 58)
        }
        .padding(12)
        .background(
            colorScheme == .dark ? Color.white.opacity(0.08) : Color.white.opacity(0.1),
            in: RoundedRectangle(cornerRadius: 16, style: .continuous)
        )
    }
}

private struct CapsuleMetric: View {
    @Environment(\.colorScheme) private var colorScheme
    let title: String
    let value: String

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title)
                .font(.caption2)
                .foregroundStyle(.secondary)
            Text(value)
                .font(.headline.monospacedDigit())
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .background(
            colorScheme == .dark ? Color.white.opacity(0.08) : Color.white.opacity(0.12),
            in: RoundedRectangle(cornerRadius: 12, style: .continuous)
        )
    }
}

private struct StatusHostRow: View {
    @Environment(\.colorScheme) private var colorScheme
    let host: HostRecord

    var body: some View {
        HStack(alignment: .center, spacing: 12) {
            Circle()
                .fill(statusColor)
                .frame(width: 8, height: 8)

            VStack(alignment: .leading, spacing: 4) {
                Text(host.displayName)
                    .font(.headline)
                    .lineLimit(1)
                Text(host.metrics?.uptime ?? subtitle)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }

            Spacer()

            if let latency = host.ping?.latencyMS {
                Text(String(format: "%.1f ms", latency))
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
            }
        }
        .padding(12)
        .background(
            colorScheme == .dark ? Color.white.opacity(0.08) : Color.white.opacity(0.1),
            in: RoundedRectangle(cornerRadius: 16, style: .continuous)
        )
    }

    private var statusColor: Color {
        switch host.sshState {
        case .authenticated: return .green
        case .metricsUnavailable: return .yellow
        case .probing: return .orange
        case .unavailable: return .red
        case .idle: return .gray
        }
    }

    private var subtitle: String {
        switch host.sshState {
        case .authenticated:
            return "Collecting metrics..."
        case .metricsUnavailable:
            return "Metrics unavailable"
        case .probing:
            return "Probing SSH..."
        case .unavailable:
            return "SSH unavailable"
        case .idle:
            return "Discovered"
        }
    }
}
