// SleepTimer — menu-bar sleep timer that pauses whatever is playing.
// Pause is sent via osascript (JXA → MediaRemote MRNowPlayingController), the method
// confirmed working on this Mac. Uses a private framework; a macOS update could break it.
//
// Resource model: no timers, polling or background work while idle. The menu is built
// only when opened. While a timer runs: one one-shot timer for the pause, plus one
// coalescable once-a-minute timer for the menu-bar countdown.
// Security model: no network, no user input reaches a shell, no special permissions.
// The only file written is ~/Library/Logs/SleepTimer.log (pause failures only). The only
// child process is /usr/bin/osascript with fixed scripts.
// If the MediaRemote pause fails, it logs it, falls back to pausing TV/Music, and posts
// a notification if nothing could be paused.

import Cocoa
import ServiceManagement
import UserNotifications

final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    private let statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
    private let presets = [15, 30, 45, 60, 90, 120]
    private var endDate: Date?
    private var endTimer: Timer?
    private var titleTimer: Timer?
    private var lastPauseFailure: (date: Date, fallbackWorked: Bool)?
    private static let logURL = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("Library/Logs/SleepTimer.log")
    private var askedForNotifications = false

    private static let timeFormatter: DateFormatter = {
        let f = DateFormatter()
        f.timeStyle = .short
        return f
    }()

    private static let pauseScript = """
    ObjC.import('Foundation');
    $.NSBundle.bundleWithPath('/System/Library/PrivateFrameworks/MediaRemote.framework/').load;
    const c = $.NSClassFromString('MRNowPlayingController').localRouteController;
    c.sendCommandOptionsCompletion(1, $.NSDictionary.alloc.init, null);
    delay(1);
    """

    /// Fallback: pause apps directly. `is running` never launches an app. Prints how many it paused.
    private static let fallbackScript = """
    set n to 0
    if application "TV" is running then
        tell application "TV" to pause
        set n to n + 1
    end if
    if application "Music" is running then
        tell application "Music" to pause
        set n to n + 1
    end if
    return n
    """

    func applicationDidFinishLaunching(_ notification: Notification) {
        updateStatusItem()
        let menu = NSMenu()
        menu.delegate = self            // populated lazily in menuNeedsUpdate
        statusItem.menu = menu
    }

    // MARK: Menu (built only when opened)

    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        if let failed = lastPauseFailure {
            let time = Self.timeFormatter.string(from: failed.date)
            add(menu, failed.fallbackWorked ? "⚠️ Normal pause failed at \(time) (fallback used)"
                                            : "⚠️ Pause failed at \(time)", #selector(openLog))
            menu.addItem(.separator())
        }
        if let end = endDate {
            menu.addItem(withTitle: "Pausing at \(Self.timeFormatter.string(from: end))", action: nil, keyEquivalent: "")
            add(menu, "Add 15 Minutes", #selector(addFifteen))
            add(menu, "Cancel Timer", #selector(cancelTimer))
        } else {
            for m in presets {
                add(menu, label(minutes: m), #selector(startPreset(_:))).tag = m
            }
        }
        menu.addItem(.separator())
        add(menu, "Pause Now", #selector(pauseNow))
        menu.addItem(.separator())
        add(menu, "Launch at Login", #selector(toggleLaunchAtLogin)).state =
            SMAppService.mainApp.status == .enabled ? .on : .off
        add(menu, "Quit Sleep Timer", #selector(NSApplication.terminate(_:))).target = NSApp
    }

    @discardableResult
    private func add(_ menu: NSMenu, _ title: String, _ action: Selector) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: "")
        item.target = self
        menu.addItem(item)
        return item
    }

    private func label(minutes m: Int) -> String {
        if m < 60 { return "\(m) Minutes" }
        if m % 60 == 0 { return m == 60 ? "1 Hour" : "\(m / 60) Hours" }
        return "\(m / 60) hr \(m % 60) min"
    }

    // MARK: Timer

    @objc private func startPreset(_ sender: NSMenuItem) {
        schedule(end: Date().addingTimeInterval(TimeInterval(sender.tag * 60)))
    }

    @objc private func addFifteen() {
        guard let end = endDate else { return }
        schedule(end: end.addingTimeInterval(15 * 60))
    }

    @objc private func cancelTimer() { stop() }

    @objc private func pauseNow() {
        askForNotificationsOnce()
        stop()
        pauseMedia()
    }

    private func schedule(end: Date) {
        askForNotificationsOnce()
        invalidateTimers()
        endDate = end

        let fire = Timer(fire: end, interval: 0, repeats: false) { [weak self] _ in
            self?.stop()
            self?.pauseMedia()
        }
        fire.tolerance = 2
        RunLoop.main.add(fire, forMode: .common)
        endTimer = fire

        let tick = Timer(timeInterval: 60, repeats: true) { [weak self] _ in self?.updateStatusItem() }
        tick.tolerance = 10              // lets macOS batch wakeups
        RunLoop.main.add(tick, forMode: .common)
        titleTimer = tick

        updateStatusItem()
    }

    // MARK: Menu-bar item

    /// Idle: a template moon that follows the menu-bar colour. Running: a blue countdown pill.
    private func updateStatusItem() {
        guard let end = endDate else {
            statusItem.button?.image = NSImage(systemSymbolName: "moon.zzz", accessibilityDescription: "Sleep Timer")
            return
        }
        let mins = max(1, Int((end.timeIntervalSinceNow / 60).rounded(.up)))
        statusItem.button?.image = Self.pillImage(minutes: mins)
    }

    private static func pillImage(minutes: Int) -> NSImage {
        let text = "\(minutes)m" as NSString
        let attributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.monospacedDigitSystemFont(ofSize: 12, weight: .semibold),
            .foregroundColor: NSColor.white,
        ]
        let config = NSImage.SymbolConfiguration(pointSize: 12, weight: .semibold)
            .applying(.init(paletteColors: [.white]))
        let moon = NSImage(systemSymbolName: "moon.zzz", accessibilityDescription: nil)?
            .withSymbolConfiguration(config)
        let moonSize = moon?.size ?? .zero
        let textSize = text.size(withAttributes: attributes)
        let padding: CGFloat = 7, gap: CGFloat = 4, height: CGFloat = 20
        let width = ceil(padding * 2 + moonSize.width + gap + textSize.width)

        let image = NSImage(size: NSSize(width: width, height: height), flipped: false) { rect in
            NSColor(srgbRed: 0x25 / 255, green: 0x63 / 255, blue: 0xEB / 255, alpha: 1).setFill()
            NSBezierPath(roundedRect: rect, xRadius: height / 2, yRadius: height / 2).fill()
            moon?.draw(in: NSRect(origin: NSPoint(x: padding, y: (height - moonSize.height) / 2), size: moonSize))
            text.draw(at: NSPoint(x: padding + moonSize.width + gap, y: (height - textSize.height) / 2),
                      withAttributes: attributes)
            return true
        }
        image.isTemplate = false         // keep our colours; templates are drawn monochrome
        image.accessibilityDescription = "Sleep Timer, \(minutes) minutes left"
        return image
    }

    private func stop() {
        invalidateTimers()
        endDate = nil
        updateStatusItem()
    }

    private func invalidateTimers() {
        endTimer?.invalidate(); endTimer = nil
        titleTimer?.invalidate(); titleTimer = nil
    }

    // MARK: Launch at login

    @objc private func toggleLaunchAtLogin() {
        let service = SMAppService.mainApp
        do {
            if service.status == .enabled {
                try service.unregister()
            } else {
                try service.register()
            }
        } catch {
            let alert = NSAlert()
            alert.messageText = "Couldn't change Launch at Login"
            alert.informativeText = error.localizedDescription
            NSApp.activate(ignoringOtherApps: true)
            alert.runModal()
        }
        if service.status == .requiresApproval {
            SMAppService.openSystemSettingsLoginItems()
        }
    }

    // MARK: Pause

    /// MediaRemote first. If osascript errors or hangs, pause TV/Music directly.
    /// If that also finds nothing to stop, notify and flag it in the menu.
    /// Limit: a MediaRemote call that exits cleanly but pauses nothing can't be detected.
    private func pauseMedia() {
        runOsascript(["-l", "JavaScript", "-e", Self.pauseScript]) { [weak self] ok, _, err in
            guard let self else { return }
            if ok { self.lastPauseFailure = nil; return }
            // Logged even if the fallback works: this is the signal that a macOS update broke MediaRemote.
            self.logFailure("MediaRemote pause failed: \(err.isEmpty ? "no error output" : err)")
            self.runOsascript(["-e", Self.fallbackScript]) { ok, out, err2 in
                let paused = ok ? (Int(out) ?? 0) : 0
                if !ok { self.logFailure("Fallback pause failed: \(err2.isEmpty ? "no error output" : err2)") }
                let worked = paused > 0
                self.logFailure(worked ? "Fallback paused \(paused) app(s) (TV/Music)"
                                       : "Nothing was paused")
                self.lastPauseFailure = (Date(), worked)
                if !worked { self.notifyPauseFailed(detail: err.isEmpty ? err2 : err) }
            }
        }
    }

    /// Appends one line with the macOS version, so failures after an OS update are easy to trace.
    private func logFailure(_ message: String) {
        NSLog("SleepTimer: %@", message)
        let os = ProcessInfo.processInfo.operatingSystemVersionString
        let line = "\(ISO8601DateFormatter().string(from: Date())) [macOS \(os)] \(message)\n"
        let data = Data(line.utf8)
        if let h = try? FileHandle(forWritingTo: Self.logURL) {
            defer { try? h.close() }
            _ = try? h.seekToEnd()
            try? h.write(contentsOf: data)
        } else {
            try? data.write(to: Self.logURL)
        }
    }

    @objc private func openLog() { NSWorkspace.shared.open(Self.logURL) }   // opens in Console

    /// Runs osascript with a fixed script; calls back on the main thread with (exited 0, stdout, stderr).
    /// Killed after 10 s so a hang counts as a failure.
    private func runOsascript(_ args: [String], completion: @escaping (Bool, String, String) -> Void) {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")   // absolute path: no PATH lookup
        p.arguments = args                                             // fixed scripts, no interpolation
        let out = Pipe(), err = Pipe()
        p.standardOutput = out
        p.standardError = err
        p.terminationHandler = { p in
            let read = { (pipe: Pipe) in
                String(decoding: pipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
                    .trimmingCharacters(in: .whitespacesAndNewlines)
            }
            let ok = p.terminationReason == .exit && p.terminationStatus == 0
            let (o, e) = (read(out), read(err))
            DispatchQueue.main.async { completion(ok, o, e) }
        }
        do {
            try p.run()
        } catch {
            completion(false, "", error.localizedDescription)
            return
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 10) { if p.isRunning { p.terminate() } }
    }

    // MARK: Notifications

    /// Asked when the user starts a timer (awake), not at 2 AM when a pause fails.
    private func askForNotificationsOnce() {
        guard !askedForNotifications else { return }
        askedForNotifications = true
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert]) { _, _ in }
    }

    private func notifyPauseFailed(detail: String) {
        let content = UNMutableNotificationContent()
        content.title = "Sleep Timer couldn't pause"
        content.body = detail.isEmpty
            ? "Nothing responded to the pause. Try Pause Now to check."
            : String(detail.prefix(200))
        let request = UNNotificationRequest(identifier: "pause-failed", content: content, trigger: nil)
        UNUserNotificationCenter.current().add(request)
    }
}

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(.accessory)   // menu bar only, no Dock icon
app.run()
