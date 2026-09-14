import Cocoa

// MARK: - Talking to the privileged helper
//
// All fan *writes* are done by the already-installed root daemon
// (com.kirtan.friday.fan-helper) over its Unix socket, which is root:admin and
// so reachable by any admin user. That means this app needs no privileges of
// its own and never has to ask for a password.

struct FanStatus {
    var actual = -1.0      // current RPM
    var floorRPM = -1.0    // the minimum the helper is currently enforcing
    var stock = -1.0       // factory minimum, restored by "auto"
    var maxRPM = -1.0      // hardware ceiling
    var mode = "unknown"   // "auto" | "max"
}

enum FanHelper {
    static let socketPath = "/var/run/com.kirtan.friday.fan.sock"

    static func send(_ command: String, timeout: Int = 2) -> String? {
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { return nil }
        defer { close(fd) }

        // Never let a wedged helper freeze the menu.
        var tv = timeval(tv_sec: timeout, tv_usec: 0)
        setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &tv, socklen_t(MemoryLayout<timeval>.size))
        setsockopt(fd, SOL_SOCKET, SO_SNDTIMEO, &tv, socklen_t(MemoryLayout<timeval>.size))

        var addr = sockaddr_un()
        addr.sun_family = sa_family_t(AF_UNIX)
        addr.sun_len = UInt8(MemoryLayout<sockaddr_un>.size)
        let path = Array(socketPath.utf8)
        guard path.count < MemoryLayout.size(ofValue: addr.sun_path) else { return nil }
        withUnsafeMutableBytes(of: &addr.sun_path) { $0.copyBytes(from: path) }

        let connected = withUnsafePointer(to: &addr) { p in
            p.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                connect(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) == 0
            }
        }
        guard connected else { return nil }

        let payload = Array((command + "\n").utf8)
        let written = payload.withUnsafeBufferPointer { write(fd, $0.baseAddress, $0.count) }
        guard written == payload.count else { return nil }

        var buf = [UInt8](repeating: 0, count: 512)
        let n = buf.withUnsafeMutableBufferPointer { read(fd, $0.baseAddress, $0.count) }
        guard n > 0 else { return nil }
        return String(decoding: buf[0..<n], as: UTF8.self)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// nil means the helper is unreachable (not running, or socket gone).
    static func status() -> FanStatus? {
        guard let reply = send("STATUS"), reply.hasPrefix("OK") else { return nil }
        var s = FanStatus()
        for field in reply.split(separator: " ") {
            let kv = field.split(separator: "=", maxSplits: 1)
            guard kv.count == 2 else { continue }
            let key = String(kv[0]), raw = String(kv[1])
            if key == "mode" { s.mode = raw; continue }
            guard let value = Double(raw) else { continue }
            switch key {
            case "actual": s.actual = value
            case "floor":  s.floorRPM = value
            case "stock":  s.stock = value
            case "max":    s.maxRPM = value
            default:       break
            }
        }
        return s
    }

    @discardableResult
    static func setMode(_ mode: String) -> Bool {
        send("MODE \(mode)")?.hasPrefix("OK") ?? false
    }
}

// MARK: - Menu bar app

final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {

    private let statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
    private let menu = NSMenu()
    private let io = DispatchQueue(label: "com.kirtan.fanblast.io")
    private var timer: Timer?

    private let readoutItem = NSMenuItem(title: "Checking…", action: nil, keyEquivalent: "")
    private let warningItem = NSMenuItem(title: "", action: nil, keyEquivalent: "")
    private let loginToggle = NSMenuItem(title: "Open at Login", action: #selector(toggleLogin), keyEquivalent: "")

    /// The two modes sit side by side: one control, one click, and the selected
    /// segment *is* the mode indicator — no checkmarks needed.
    private let modeControl = NSSegmentedControl(
        labels: ["Automatic", "Jet Mode"],
        trackingMode: .selectOne,
        target: nil,
        action: nil
    )

    func applicationDidFinishLaunching(_ notification: Notification) {
        smc_start()
        buildMenu()
        statusItem.menu = menu
        refresh()
        startPolling(every: Self.idleInterval, tolerance: Self.idleInterval * 0.3)
    }

    /// Poll cadence. The readout is only on screen while the menu is open, so
    /// that is the only time it needs to be quick; the rest of the time this is
    /// just keeping the icon in sync and the helper's 15-minute watchdog fed,
    /// which a generous tolerance lets macOS coalesce with other wakeups.
    private static let liveInterval: TimeInterval = 1.0
    private static let idleInterval: TimeInterval = 3.0

    private func startPolling(every interval: TimeInterval, tolerance: TimeInterval) {
        timer?.invalidate()
        let t = Timer(timeInterval: interval, repeats: true) { [weak self] _ in
            self?.refresh()
        }
        t.tolerance = tolerance
        // .common, not the default mode: while a menu is tracking, the run loop
        // is in event-tracking mode and a default-mode timer never fires — the
        // readout froze for exactly as long as the menu was open.
        RunLoop.main.add(t, forMode: .common)
        timer = t
    }

    func applicationWillTerminate(_ notification: Notification) {
        timer?.invalidate()
        smc_stop()
    }

    private func buildMenu() {
        menu.delegate = self

        readoutItem.isEnabled = false
        menu.addItem(readoutItem)

        menu.addItem(modeSwitchItem())
        menu.addItem(.separator())

        warningItem.isEnabled = false
        warningItem.isHidden = true
        menu.addItem(warningItem)

        loginToggle.target = self
        menu.addItem(loginToggle)

        menu.addItem(.separator())
        menu.addItem(NSMenuItem(title: "Quit FanBlast",
                                action: #selector(NSApplication.terminate(_:)),
                                keyEquivalent: "q"))
    }

    /// A menu item whose content is the segmented control. Menus lay custom
    /// views out themselves, so the container carries the padding that a normal
    /// menu item would get for free.
    private func modeSwitchItem() -> NSMenuItem {
        modeControl.segmentStyle = .rounded
        modeControl.target = self
        modeControl.action = #selector(modeChanged(_:))
        modeControl.selectedSegment = 0
        modeControl.setWidth(96, forSegment: 0)   // equal halves, wider than either label
        modeControl.setWidth(96, forSegment: 1)

        // Size the container from what the control actually needs. Hardcoding it
        // clipped the labels: two 96pt segments want 201pt, not the 192pt that a
        // 220pt-wide container leaves after padding.
        let fitting = modeControl.fittingSize
        let inset: CGFloat = 14
        let container = NSView(frame: NSRect(x: 0, y: 0,
                                             width: fitting.width + inset * 2,
                                             height: fitting.height + 8))
        modeControl.frame = NSRect(x: inset, y: 4, width: fitting.width, height: fitting.height)
        container.addSubview(modeControl)

        let item = NSMenuItem()
        item.view = container
        return item
    }

    func menuWillOpen(_ menu: NSMenu) {
        refresh()
        startPolling(every: Self.liveInterval, tolerance: 0.1)
    }

    func menuDidClose(_ menu: NSMenu) {
        startPolling(every: Self.idleInterval, tolerance: Self.idleInterval * 0.3)
    }

    // MARK: Actions

    @objc private func modeChanged(_ sender: NSSegmentedControl) {
        apply(sender.selectedSegment == 1 ? "max" : "auto")
        // A custom view does not dismiss the menu on click the way a plain item
        // does, so close it explicitly.
        menu.cancelTracking()
    }

    private func apply(_ mode: String) {
        io.async { [weak self] in
            let ok = FanHelper.setMode(mode)
            let status = FanHelper.status()
            DispatchQueue.main.async { self?.render(status, failed: !ok) }
        }
    }

    private func refresh() {
        io.async { [weak self] in
            let status = FanHelper.status()
            DispatchQueue.main.async { self?.render(status) }
        }
    }

    // MARK: Rendering

    private func cpuTemperature() -> Double {
        // TCXC is the PECI core reading on this vintage; the others are fallbacks
        // for Macs that do not publish it.
        for key in ["TCXC", "TC0E", "TC0P"] {
            let value = smc_number(key)
            if value > 0 && value < 130 { return value }
        }
        return -1
    }

    private func render(_ status: FanStatus?, failed: Bool = false) {
        guard let status else {
            setIcon(jet: false)
            readoutItem.title = "Fan helper not running"
            modeControl.isEnabled = false
            warningItem.title = "Start com.kirtan.friday.fan-helper to control the fan"
            warningItem.isHidden = false
            updateLoginToggle()
            return
        }

        modeControl.isEnabled = true

        let isJet = status.mode == "max"
        modeControl.selectedSegment = isJet ? 1 : 0
        setIcon(jet: isJet)

        // The menu bar shows the icon alone, so the numbers live in the menu.
        let rpm = status.actual >= 0 ? status.actual : smc_number("F0Ac")
        let temp = cpuTemperature()
        var readout: [String] = []
        if rpm >= 0 { readout.append("\(Int(rpm.rounded())) RPM") }
        if temp >= 0 { readout.append("\(Int(temp.rounded()))°C") }
        readoutItem.title = readout.isEmpty ? "Fan running" : readout.joined(separator: " · ")

        // Jet Mode is safe from interference: the helper raises the fan's
        // *minimum*, and effective speed is max(minimum, target), so another
        // app's forced target cannot undercut a raised floor. Automatic is the
        // mode that loses — a third-party override (FS! != 0) pins the target
        // and macOS never gets the fan back down. Only warn when it matters.
        let forcedByOther = smc_number("FS! ") > 0
        if failed {
            warningItem.title = "Could not change mode — helper refused"
            warningItem.isHidden = false
        } else if !isJet && forcedByOther {
            warningItem.title = "Another app is forcing the fan — Automatic can't slow it"
            warningItem.isHidden = false
        } else {
            warningItem.isHidden = true
        }

        updateLoginToggle()
    }

    /// Icon only — no RPM text. Outline for Automatic, filled plus the system
    /// accent tint for Jet Mode, so the two read apart at a glance in a
    /// monochrome menu bar.
    private func setIcon(jet: Bool) {
        guard let button = statusItem.button else { return }
        button.title = ""
        let image = NSImage(systemSymbolName: jet ? "fanblades.fill" : "fanblades",
                            accessibilityDescription: jet ? "Fan: Jet Mode" : "Fan: Automatic")
        image?.isTemplate = true
        button.image = image
        button.contentTintColor = jet ? .controlAccentColor : nil
        if image == nil { button.title = jet ? "JET" : "FAN" }   // symbol unavailable
    }

    // MARK: Open at Login
    //
    // A plain LaunchAgent rather than SMAppService: this app is ad-hoc signed,
    // and a LaunchAgent plist works regardless of signing identity.

    private var launchAgentURL: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/LaunchAgents/com.kirtan.fanblast.plist")
    }

    private func updateLoginToggle() {
        loginToggle.state = FileManager.default.fileExists(atPath: launchAgentURL.path) ? .on : .off
    }

    @objc private func toggleLogin() {
        let fm = FileManager.default
        let url = launchAgentURL

        if fm.fileExists(atPath: url.path) {
            try? fm.removeItem(at: url)
        } else if let executable = Bundle.main.executablePath {
            let plist: [String: Any] = [
                "Label": "com.kirtan.fanblast",
                "ProgramArguments": [executable],
                "RunAtLoad": true,
                "KeepAlive": false,
                "ProcessType": "Interactive",
            ]
            try? fm.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            if let data = try? PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0) {
                try? data.write(to: url)
            }
        }
        updateLoginToggle()
    }
}

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(.accessory)   // menu bar only: no Dock icon, no window
app.run()
