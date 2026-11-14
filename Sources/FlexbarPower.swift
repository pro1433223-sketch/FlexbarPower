import AppKit
import SwiftUI
import Combine
import Foundation

@objc protocol FlexbarPowerProtocol {
    func status(reply: @escaping (String, Int32) -> Void)
    func setPower(_ enabled: Bool, reply: @escaping (String, Int32) -> Void)
    func cycle(reply: @escaping (String, Int32) -> Void)
}

@MainActor
final class PowerModel: ObservableObject {
    @Published var isOn: Bool? = nil
    @Published var busy = false
    @Published var progress: CGFloat = 1
    @Published var message = "正在读取 Flexbar 状态…"
    @Published var autoPowerOnUnlock = UserDefaults.standard.bool(forKey: "autoPowerOnUnlock") {
        didSet { UserDefaults.standard.set(autoPowerOnUnlock, forKey: "autoPowerOnUnlock") }
    }
    @Published var autoPowerOffLock = UserDefaults.standard.bool(forKey: "autoPowerOffLock") {
        didSet { UserDefaults.standard.set(autoPowerOffLock, forKey: "autoPowerOffLock") }
    }

    private var animationTimer: Timer?

    func load() {
        guard !busy, isOn == nil else { return }
        busy = true
        Task {
            if !Self.helperInstalled {
                let result = await Task.detached { Self.installHelper() }.value
                guard result.0 else {
                    message = result.1.isEmpty ? "首次设置未完成。请重新打开 FlexbarPower 并授权。" : result.1
                    busy = false
                    return
                }
            }
            await refreshStatus()
            busy = false
        }
    }

    func setPower(_ enabled: Bool) {
        guard !busy else { return }
        busy = true
        message = enabled ? "正在开启 Flexbar…" : "正在关闭 Flexbar…"
        Task {
            do {
                let result = try await Self.request { proxy, reply in proxy.setPower(enabled, reply: reply) }
                guard result.1 == 0 else {
                    message = result.0.isEmpty ? "电源切换失败。" : result.0
                    await refreshStatus()
                    busy = false
                    return
                }
                isOn = enabled
                progress = enabled ? 1 : 0
                message = enabled ? "Flexbar 已开启" : "Flexbar 已关闭"
            } catch {
                message = "无法连接辅助程序：\(error.localizedDescription)"
            }
            busy = false
        }
    }

    func powerOnAfterSystemUnlock() {
        guard autoPowerOnUnlock else { return }
        setPowerToExpectedState(true)
    }

    func powerOffAfterSystemLock() {
        guard autoPowerOffLock else { return }
        setPowerToExpectedState(false)
    }

    private func setPowerToExpectedState(_ enabled: Bool) {
        Task {
            guard !busy else { return }
            if isOn == nil { await refreshStatus() }
            guard isOn != nil, isOn != enabled, !busy else { return }
            setPower(enabled)
        }
    }

    func restart() {
        guard !busy else { return }
        busy = true
        message = "正在重启 Flexbar…"
        progress = 0
        startAnimation()
        Task {
            do {
                let result = try await Self.request { proxy, reply in proxy.cycle(reply: reply) }
                animationTimer?.invalidate()
                if result.1 == 0 {
                    isOn = true
                    progress = 1
                    message = "Flexbar 已重新供电"
                } else {
                    progress = isOn == true ? 1 : 0
                    message = result.0.isEmpty ? "Flexbar 重启失败。" : result.0
                }
            } catch {
                animationTimer?.invalidate()
                progress = isOn == true ? 1 : 0
                message = "无法连接辅助程序：\(error.localizedDescription)"
            }
            busy = false
        }
    }

    private func refreshStatus() async {
        do {
            let result = try await Self.request { proxy, reply in proxy.status(reply: reply) }
            guard result.1 == 0 else {
                isOn = nil
                message = result.0.isEmpty ? "无法读取 USB 端口状态" : result.0
                return
            }
            let states = result.0.split(separator: "\n").compactMap { line -> Bool? in
                guard line.contains("Port 2:") else { return nil }
                if line.localizedCaseInsensitiveContains(" off") { return false }
                if line.localizedCaseInsensitiveContains(" power") { return true }
                return nil
            }
            guard let first = states.first, states.allSatisfy({ $0 == first }) else {
                isOn = nil
                message = states.isEmpty ? "无法识别 Port 2 的供电状态" : "USB Hub 的端口状态不一致，请检查连接"
                return
            }
            isOn = first
            progress = first ? 1 : 0
            message = first ? "Flexbar 已开启" : "Flexbar 已关闭"
        } catch {
            isOn = nil
            message = "状态读取失败：\(error.localizedDescription)"
        }
    }

    private func startAnimation() {
        let started = Date()
        animationTimer?.invalidate()
        animationTimer = Timer.scheduledTimer(withTimeInterval: 1.0 / 30.0, repeats: true) { [weak self] _ in
            Task { @MainActor in
                guard let self else { return }
                self.progress = min(1, Date().timeIntervalSince(started) / 3)
                if self.progress >= 1 { self.animationTimer?.invalidate() }
            }
        }
    }

    private static var helperInstalled: Bool {
        let helper = "/Library/PrivilegedHelperTools/local.flexbar.power.helper"
        let plist = "/Library/LaunchDaemons/local.flexbar.power.helper.plist"
        let version = "/Library/PrivilegedHelperTools/local.flexbar.power.helper.version"
        guard FileManager.default.isExecutableFile(atPath: helper), FileManager.default.fileExists(atPath: plist),
              let installedVersion = try? String(contentsOfFile: version, encoding: .utf8).trimmingCharacters(in: .whitespacesAndNewlines) else { return false }
        return installedVersion == "2"
    }

    nonisolated private static func installHelper() -> (Bool, String) {
        guard FileManager.default.isExecutableFile(atPath: "/opt/homebrew/bin/uhubctl") else {
            return (false, "找不到 /opt/homebrew/bin/uhubctl。请先安装 uhubctl。")
        }
        let appPath = Bundle.main.bundlePath
        let helper = "\(appPath)/Contents/Library/LaunchServices/FlexbarPowerHelper"
        let plist = "\(appPath)/Contents/Library/LaunchDaemons/local.flexbar.power.helper.plist"
        func quote(_ value: String) -> String { "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'" }
        let daemonPlist = "/Library/LaunchDaemons/local.flexbar.power.helper.plist"
        let helperPath = "/Library/PrivilegedHelperTools/local.flexbar.power.helper"
        let marker = "/Library/PrivilegedHelperTools/local.flexbar.power.helper.version"
        let shell = "/bin/mkdir -p /Library/PrivilegedHelperTools && (/bin/launchctl bootout system \(quote(daemonPlist)) >/dev/null 2>&1 || true) && /bin/cp \(quote(helper)) \(quote(helperPath)) && /usr/sbin/chown root:wheel \(quote(helperPath)) && /bin/chmod 755 \(quote(helperPath)) && /bin/cp \(quote(plist)) \(quote(daemonPlist)) && /usr/sbin/chown root:wheel \(quote(daemonPlist)) && /bin/chmod 644 \(quote(daemonPlist)) && /bin/launchctl bootstrap system \(quote(daemonPlist)) && /bin/echo -n 2 > \(quote(marker)) && /usr/sbin/chown root:wheel \(quote(marker)) && /bin/chmod 644 \(quote(marker))"
        let escaped = shell.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"")
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
        process.arguments = ["-e", "do shell script \"\(escaped)\" with administrator privileges"]
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe
        do {
            try process.run()
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            process.waitUntilExit()
            return (process.terminationStatus == 0, String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines))
        } catch { return (false, error.localizedDescription) }
    }

    nonisolated private static func request(_ action: (FlexbarPowerProtocol, @escaping (String, Int32) -> Void) -> Void) async throws -> (String, Int32) {
        try await withCheckedThrowingContinuation { continuation in
            let connection = NSXPCConnection(machServiceName: "local.flexbar.power.helper", options: .privileged)
            connection.remoteObjectInterface = NSXPCInterface(with: FlexbarPowerProtocol.self)
            connection.resume()
            let proxy = connection.remoteObjectProxyWithErrorHandler { error in
                connection.invalidate()
                continuation.resume(throwing: error)
            }
            guard let typedProxy = proxy as? FlexbarPowerProtocol else {
                connection.invalidate()
                continuation.resume(throwing: NSError(domain: "FlexbarPower", code: 1, userInfo: [NSLocalizedDescriptionKey: "辅助程序不可用"]))
                return
            }
            action(typedProxy) { output, status in
                connection.invalidate()
                continuation.resume(returning: (output, status))
            }
        }
    }
}

struct ControlView: View {
    @EnvironmentObject private var model: PowerModel
    var onRestart: () -> Void = {}

    var body: some View {
        VStack(spacing: 10) {
            HStack(spacing: 9) {
                Image(systemName: "bolt.horizontal.circle.fill")
                    .font(.system(size: 20))
                    .foregroundStyle(.green)
                Text("FlexbarPower").font(.system(size: 17, weight: .semibold))
                Spacer()
                Button("退出") { NSApp.terminate(nil) }
                    .buttonStyle(.plain)
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
            }
            HStack {
                VStack(alignment: .leading, spacing: 3) {
                    Text("Flexbar 电源").font(.system(size: 14, weight: .medium))
                    Text(model.isOn.map { $0 ? "当前已开启" : "当前已关闭" } ?? "正在读取状态")
                        .font(.system(size: 11)).foregroundStyle(.secondary)
                }
                Spacer()
                Toggle("Flexbar 电源", isOn: Binding(
                    get: { model.isOn ?? false },
                    set: { model.setPower($0) }
                ))
                .labelsHidden()
                .toggleStyle(.switch)
                .disabled(model.busy || model.isOn == nil)
            }
            Divider()
            HStack {
                VStack(alignment: .leading, spacing: 4) {
                    Text("重启 Flexbar").font(.system(size: 14, weight: .medium))
                    Text("断电 3 秒后恢复供电").font(.system(size: 11)).foregroundStyle(.secondary)
                }
                Spacer()
                Button("重启") {
                    onRestart()
                    model.restart()
                }
                    .buttonStyle(.borderedProminent)
                    .disabled(model.busy || model.isOn == nil)
            }
            Divider()
            HStack(spacing: 8) {
                Text("跟随系统唤醒自动开机")
                Spacer(minLength: 0)
                Toggle("跟随系统唤醒自动开机", isOn: $model.autoPowerOnUnlock)
                    .labelsHidden()
                    .toggleStyle(.checkbox)
                    .controlSize(.small)
            }
            HStack(spacing: 8) {
                Text("跟随系统锁屏自动断电")
                Spacer(minLength: 0)
                Toggle("跟随系统锁屏自动断电", isOn: $model.autoPowerOffLock)
                    .labelsHidden()
                    .toggleStyle(.checkbox)
                    .controlSize(.small)
            }
        }
        .padding(16)
        .frame(width: 326, height: 242)
        .background(Color(nsColor: .windowBackgroundColor))
    }
}

private extension NSTouchBarItem.Identifier {
    static let flexbarPowerOff = NSTouchBarItem.Identifier("local.flexbar.power.touchbar-off")
    static let flexbarPowerRestart = NSTouchBarItem.Identifier("local.flexbar.power.touchbar-restart")
}

@MainActor
final class PowerTouchBarController: NSHostingController<AnyView>, NSTouchBarDelegate {
    private let model: PowerModel
    private var powerOffButton: NSButton?
    private var restartButton: NSButton?
    private var stateSubscription: AnyCancellable?

    init(model: PowerModel, onRestart: @escaping () -> Void) {
        self.model = model
        super.init(rootView: AnyView(ControlView(onRestart: onRestart).environmentObject(model)))
        stateSubscription = model.$isOn.combineLatest(model.$busy)
            .receive(on: RunLoop.main)
            .sink { [weak self] isOn, busy in self?.refreshButtons(isOn: isOn, busy: busy) }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is unavailable") }

    override func makeTouchBar() -> NSTouchBar? {
        let bar = NSTouchBar()
        bar.delegate = self
        bar.customizationIdentifier = NSTouchBar.CustomizationIdentifier("local.flexbar.power.touchbar")
        bar.defaultItemIdentifiers = [.flexbarPowerOff, .flexbarPowerRestart, .otherItemsProxy]
        bar.customizationAllowedItemIdentifiers = [.flexbarPowerOff, .flexbarPowerRestart]
        bar.principalItemIdentifier = .flexbarPowerRestart
        return bar
    }

    func touchBar(_ touchBar: NSTouchBar, makeItemForIdentifier identifier: NSTouchBarItem.Identifier) -> NSTouchBarItem? {
        switch identifier {
        case .flexbarPowerOff:
            let item = NSCustomTouchBarItem(identifier: identifier)
            let icon = NSImage(systemSymbolName: "power", accessibilityDescription: "关闭 Flexbar 电源") ?? NSImage()
            let button = NSButton(title: "关闭 Flexbar", image: icon, target: self, action: #selector(turnPowerOff))
            button.bezelColor = .systemRed
            item.view = button
            powerOffButton = button
            refreshButtons(isOn: model.isOn, busy: model.busy)
            return item
        case .flexbarPowerRestart:
            let item = NSCustomTouchBarItem(identifier: identifier)
            let icon = NSImage(systemSymbolName: "arrow.clockwise", accessibilityDescription: "重启 Flexbar") ?? NSImage()
            let button = NSButton(title: "重启", image: icon, target: self, action: #selector(restartFlexbar))
            button.bezelColor = .systemBlue
            item.view = button
            restartButton = button
            refreshButtons(isOn: model.isOn, busy: model.busy)
            return item
        default:
            return nil
        }
    }

    @objc private func turnPowerOff() {
        guard model.isOn == true, !model.busy else { return }
        model.setPower(false)
    }

    @objc private func restartFlexbar() {
        guard model.isOn != nil, !model.busy else { return }
        model.restart()
    }

    private func refreshButtons(isOn: Bool?, busy: Bool) {
        powerOffButton?.isEnabled = isOn == true && !busy
        restartButton?.isEnabled = isOn != nil && !busy
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, NSPopoverDelegate {
    let model = PowerModel()
    private var statusItem: NSStatusItem!
    private var popover = NSPopover()
    private var progressSubscription: AnyCancellable?
    private var touchBarController: PowerTouchBarController!
    private let distributedNotifications = DistributedNotificationCenter.default()

    func applicationDidFinishLaunching(_ notification: Notification) {
        statusItem = NSStatusBar.system.statusItem(withLength: 30)
        if let button = statusItem.button {
            button.image = NSImage(systemSymbolName: "bolt.horizontal.circle.fill", accessibilityDescription: "FlexbarPower")
            button.image?.isTemplate = true
            button.target = self
            button.action = #selector(togglePopover)
            button.toolTip = "FlexbarPower — Flexbar 电源控制"
        }
        popover.behavior = .transient
        popover.contentSize = NSSize(width: 326, height: 242)
        popover.delegate = self
        touchBarController = PowerTouchBarController(model: model, onRestart: { [weak self] in self?.popover.performClose(nil) })
        popover.contentViewController = touchBarController
        progressSubscription = model.$progress.sink { [weak self] value in
            Task { @MainActor in self?.statusItem.button?.image = self?.makeStatusIcon(progress: value) }
        }
        model.load()
        distributedNotifications.addObserver(
            self,
            selector: #selector(systemDidUnlock),
            name: Notification.Name("com.apple.screenIsUnlocked"),
            object: nil
        )
        distributedNotifications.addObserver(
            self,
            selector: #selector(systemDidLock),
            name: Notification.Name("com.apple.screenIsLocked"),
            object: nil
        )
    }

    @objc private func systemDidUnlock(_ notification: Notification) {
        DispatchQueue.main.async { [weak self] in
            self?.model.powerOnAfterSystemUnlock()
        }
    }

    @objc private func systemDidLock(_ notification: Notification) {
        DispatchQueue.main.async { [weak self] in
            self?.model.powerOffAfterSystemLock()
        }
    }

    @objc private func togglePopover() {
        guard let button = statusItem.button else { return }
        if popover.isShown { popover.performClose(nil) }
        else {
            _ = NSApp.setActivationPolicy(.regular)
            NSApp.activate(ignoringOtherApps: true)
            let touchBar = touchBarController.makeTouchBar()
            popover.touchBar = touchBar
            NSApp.touchBar = touchBar
            popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
            DispatchQueue.main.async { [weak self] in
                guard let self, self.popover.isShown else { return }
                self.popover.contentViewController?.view.window?.makeKeyAndOrderFront(nil)
                NSApp.activate(ignoringOtherApps: true)
                NSApp.touchBar = self.touchBarController.makeTouchBar()
            }
        }
    }

    @objc func popoverDidClose(_ notification: Notification) {
        popover.touchBar = nil
        NSApp.touchBar = nil
        NSApp.setActivationPolicy(.accessory)
    }

    func applicationWillTerminate(_ notification: Notification) {
        distributedNotifications.removeObserver(self)
    }

    private func makeStatusIcon(progress: CGFloat) -> NSImage {
        let image = NSImage(size: NSSize(width: 34, height: 18))
        image.lockFocus()
        let shell = NSBezierPath(roundedRect: NSRect(x: 1, y: 2, width: 32, height: 14), xRadius: 5, yRadius: 5)
        NSColor(calibratedRed: 0.19, green: 0.22, blue: 0.27, alpha: 1).setFill(); shell.fill()
        NSColor(calibratedWhite: 0.78, alpha: 0.8).setStroke(); shell.lineWidth = 0.7; shell.stroke()
        let screen = NSRect(x: 3.5, y: 4.8, width: 18.4, height: 8.4)
        NSColor(calibratedRed: 0.045, green: 0.075, blue: 0.085, alpha: 1).setFill()
        NSBezierPath(roundedRect: screen, xRadius: 2.5, yRadius: 2.5).fill()
        if progress > 0 {
            let fillRect = NSRect(x: screen.minX, y: screen.minY, width: screen.width * min(1, max(0, progress)), height: screen.height)
            let fill = NSBezierPath(roundedRect: fillRect, xRadius: 2.5, yRadius: 2.5)
            NSGradient(colors: [NSColor(calibratedRed: 0.34, green: 1, blue: 0.52, alpha: 1), NSColor(calibratedRed: 0.06, green: 0.77, blue: 0.31, alpha: 1)])?.draw(in: fill, angle: 90)
        }
        NSColor(calibratedRed: 0.39, green: 0.69, blue: 1, alpha: 1).setStroke()
        let arc = NSBezierPath(); arc.lineWidth = 1.25; arc.lineCapStyle = .round
        arc.appendArc(withCenter: NSPoint(x: 27.2, y: 8.8), radius: 2.4, startAngle: 132, endAngle: 48, clockwise: false); arc.stroke()
        let stem = NSBezierPath(); stem.lineWidth = 1.25; stem.lineCapStyle = .round
        stem.move(to: NSPoint(x: 27.2, y: 11.5)); stem.line(to: NSPoint(x: 27.2, y: 8.4)); stem.stroke()
        image.unlockFocus()
        image.isTemplate = false
        return image
    }
}

@main
struct FlexbarPowerApp {
    static func main() {
        let app = NSApplication.shared
        app.setActivationPolicy(.accessory)
        let delegate = AppDelegate()
        app.delegate = delegate
        app.run()
    }
}
