// SleepTimer — menu-bar sleep timer that pauses whatever is playing.
// Pause is sent via osascript (JXA → MediaRemote MRNowPlayingController), the method
// confirmed working on this Mac. Uses a private framework; a macOS update could break it.
//
// Resource model: no timers, polling or background work while idle. The menu is built
// only when opened. While a timer runs: one one-shot timer for the pause, plus one
// coalescable once-a-minute timer for the menu-bar countdown.
// Security model: no network, no file I/O, no user input reaches a shell, no special
// permissions. The only child process is /usr/bin/osascript with a fixed script.

import Cocoa
import ServiceManagement

final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    private let statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
    private let presets = [15, 30, 45, 60, 90, 120]
    private var endDate: Date?
    private var endTimer: Timer?
    private var titleTimer: Timer?

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

    func applicationDidFinishLaunching(_ notification: Notification) {
        statusItem.button?.image = NSImage(systemSymbolName: "moon.zzz", accessibilityDescription: "Sleep Timer")
        statusItem.button?.imagePosition = .imageLeading
        let menu = NSMenu()
        menu.delegate = self            // populated lazily in menuNeedsUpdate
        statusItem.menu = menu
    }

    // MARK: Menu (built only when opened)

    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
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
        stop()
        pauseMedia()
    }

    private func schedule(end: Date) {
        invalidateTimers()
        endDate = end

        let fire = Timer(fire: end, interval: 0, repeats: false) { [weak self] _ in
            self?.stop()
            self?.pauseMedia()
        }
        fire.tolerance = 2
        RunLoop.main.add(fire, forMode: .common)
        endTimer = fire

        let tick = Timer(timeInterval: 60, repeats: true) { [weak self] _ in self?.updateTitle() }
        tick.tolerance = 10              // lets macOS batch wakeups
        RunLoop.main.add(tick, forMode: .common)
        titleTimer = tick

        updateTitle()
    }

    private func updateTitle() {
        guard let end = endDate else { statusItem.button?.title = ""; return }
        let mins = max(1, Int((end.timeIntervalSinceNow / 60).rounded(.up)))
        statusItem.button?.title = " \(mins)m"
    }

    private func stop() {
        invalidateTimers()
        endDate = nil
        statusItem.button?.title = ""
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

    private func pauseMedia() {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")   // absolute path: no PATH lookup
        p.arguments = ["-l", "JavaScript", "-e", Self.pauseScript]     // fixed script, no interpolation
        p.standardOutput = FileHandle.nullDevice
        p.standardError = FileHandle.nullDevice
        try? p.run()
    }
}

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(.accessory)   // menu bar only, no Dock icon
app.run()
