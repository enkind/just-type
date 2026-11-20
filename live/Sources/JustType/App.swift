import AppKit
import Carbon
import CoreGraphics

/// Persistent settings in ~/Library/Application Support/JustType/settings.json
struct Settings: Codable {
    var enabled = true
    var ignored: [String: String] = [:]   // bundle id -> app name (ids never shown to the user)
    var logFixes = false

    static let dir = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("Library/Application Support/JustType")
    static let file = dir.appendingPathComponent("settings.json")

    static func load() -> Settings {
        guard let d = try? Data(contentsOf: file), let s = try? JSONDecoder().decode(Settings.self, from: d) else { return Settings() }
        return s
    }

    func save() {
        try? FileManager.default.createDirectory(at: Settings.dir, withIntermediateDirectories: true)
        let enc = JSONEncoder(); enc.outputFormatting = [.prettyPrinted, .sortedKeys]
        try? enc.encode(self).write(to: Settings.file, options: .atomic)
    }
}

/// Real corrections. Nothing here blocks the event-tap callback: injections and layout
/// switches are queued onto the main queue and run, in order, right after the callback
/// returns. The current layout is a cached value kept fresh by TIS change notifications.
final class OSSink: Sink {
    private(set) var cached: Int = Layout._current()

    init() {
        DistributedNotificationCenter.default().addObserver(
            forName: NSNotification.Name(kTISNotifySelectedKeyboardInputSourceChanged as String),
            object: nil, queue: .main) { [weak self] _ in self?.cached = Layout._current() }
    }

    private func later(_ f: @escaping () -> Void) { DispatchQueue.main.async(execute: f) }

    func backspaces(_ n: Int) -> Int { if n > 0 { later { Inject.backspaces(n) } }; return n }
    func text(_ s: String) -> Int {
        if s.isEmpty { return 0 }
        later { Inject.text(s) }
        return (s.utf16.count + 15) / 16      // = number of keyDown events Inject.text posts
    }
    func repost(vk: UInt16, flags: CGEventFlags) -> Int { later { Inject.key(vk, flags: flags) }; return 1 }
    func select(_ L: Int) {
        later { [weak self] in
            if Layout._current() != L { TISSelectInputSource(Layout.sources[L]) }
            self?.cached = L
        }
    }
    func current() -> Int { cached }
}

/// Menu-bar app: status item + event tap.
final class MenuBarApp: NSObject, NSApplicationDelegate, NSMenuDelegate {
    var settings = Settings.load()
    let sink = OSSink()
    var engine: Engine!
    var tap: CFMachPort?
    var item: NSStatusItem!
    var frontID: String?, frontName: String?
    let selfID = Bundle.main.bundleIdentifier ?? "local.justtype"
    static let logURL = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Logs/JustType/fixes.log")

    init(model: ModelFiles, cfg: Config) {
        super.init()
        engine = Engine(det: Detector(model, cfg: cfg), sink: sink)
        engine.onFix = { [weak self] orig, ins in self?.logFix(orig, ins) }
        engine.onTrip = { [weak self] in DispatchQueue.main.async { self?.writeStatus(); self?.refreshIcon() } }
    }

    func applicationDidFinishLaunching(_ n: Notification) {
        item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        let menu = NSMenu()
        menu.delegate = self
        item.menu = menu
        let ws = NSWorkspace.shared
        noteFront(ws.frontmostApplication)
        ws.notificationCenter.addObserver(forName: NSWorkspace.didActivateApplicationNotification, object: nil, queue: .main) { [weak self] n in
            self?.noteFront(n.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication)
        }
        startTap()
        refreshIcon()
    }

    // ------------------------------------------------------------- focus / icon
    func noteFront(_ app: NSRunningApplication?) {
        guard let app, let id = app.bundleIdentifier, id != selfID else { return }
        frontID = id
        frontName = app.localizedName ?? id
        engine?.reset()
        refreshIcon()
    }

    var activeHere: Bool { settings.enabled && tap != nil && !(frontID.map { settings.ignored[$0] != nil } ?? false) }

    func refreshIcon() {
        guard let b = item?.button else { return }
        b.image = MenuIcon.image(suspended || (engine?.tripped ?? false) ? .paused : tap == nil ? .needsPermission : .normal)
        b.appearsDisabled = !activeHere
        b.toolTip = suspended ? "JustType stepped aside after input timeouts"
            : (engine?.tripped ?? false) ? "JustType paused itself for a minute (too many corrections)"
            : tap == nil ? "JustType needs Accessibility permission"
            : !settings.enabled ? "JustType is paused"
            : activeHere ? "JustType is on" : "JustType ignores \(frontName ?? "this app")"
    }

    // ------------------------------------------------------------- menu
    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        if suspended {
            menu.addItem(withTitle: "Paused after input timeouts — Resume", action: #selector(resume), keyEquivalent: "").target = self
            menu.addItem(.separator())
        } else if tap == nil {
            menu.addItem(withTitle: "Needs Accessibility permission…", action: #selector(openPrivacy), keyEquivalent: "").target = self
            menu.addItem(.separator())
        }
        let on = menu.addItem(withTitle: settings.enabled ? "On" : "Paused", action: #selector(toggleEnabled), keyEquivalent: "")
        on.target = self
        on.state = settings.enabled ? .on : .off
        if let id = frontID, let name = frontName {
            let ignored = settings.ignored[id] != nil
            let it = menu.addItem(withTitle: ignored ? "Stop ignoring \(name)" : "Ignore \(name)",
                                  action: #selector(toggleIgnoreFront), keyEquivalent: "")
            it.target = self
        }
        if !settings.ignored.isEmpty {
            let sub = NSMenu()
            for (id, name) in settings.ignored.sorted(by: { $0.value < $1.value }) {
                let it = sub.addItem(withTitle: "Stop ignoring \(name)", action: #selector(unignore(_:)), keyEquivalent: "")
                it.target = self
                it.representedObject = id
            }
            menu.addItem(withTitle: "Ignored apps", action: nil, keyEquivalent: "").submenu = sub
        }
        menu.addItem(.separator())
        let lg = menu.addItem(withTitle: "Log fixes", action: #selector(toggleLog), keyEquivalent: "")
        lg.target = self
        lg.state = settings.logFixes ? .on : .off
        if FileManager.default.fileExists(atPath: Self.logURL.path) {
            menu.addItem(withTitle: "Show fix log", action: #selector(showLog), keyEquivalent: "").target = self
        }
        menu.addItem(.separator())
        menu.addItem(withTitle: "Quit JustType", action: #selector(quit), keyEquivalent: "q").target = self
    }

    @objc func toggleEnabled() { settings.enabled.toggle(); settings.save(); engine.reset(); refreshIcon() }
    @objc func toggleIgnoreFront() {
        guard let id = frontID else { return }
        if settings.ignored[id] != nil { settings.ignored[id] = nil } else { settings.ignored[id] = frontName ?? id }
        settings.save(); engine.reset(); refreshIcon(); writeStatus()
    }
    @objc func unignore(_ sender: NSMenuItem) {
        if let id = sender.representedObject as? String { settings.ignored[id] = nil; settings.save(); refreshIcon() }
    }
    @objc func toggleLog() { settings.logFixes.toggle(); settings.save() }
    @objc func showLog() { NSWorkspace.shared.open(Self.logURL) }
    @objc func openPrivacy() {
        NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")!)
    }
    @objc func quit() { stopTap(); NSApp.terminate(nil) }
    @objc func resume() { suspended = false; timeouts = []; startTap() }

    func logFix(_ orig: String, _ ins: String) {
        guard settings.logFixes else { return }
        let line = "\(ISO8601DateFormatter().string(from: Date()))\t\(frontName ?? "?")\t\(orig)\t→\t\(ins)"
        DispatchQueue.global(qos: .utility).async {
            try? FileManager.default.createDirectory(at: Self.logURL.deletingLastPathComponent(), withIntermediateDirectories: true)
            log(line, to: Self.logURL.path)
        }
    }

    // ------------------------------------------------------------- event tap
    var tapSource: CFRunLoopSource?
    var permTimer: Timer?
    var timeouts: [Date] = []
    var suspended = false          // stopped itself after repeated input timeouts
    var asked = false

    /// Only create the tap once Accessibility is actually granted (no tap-creation spam while
    /// waiting); ask once per launch, then poll the cheap trust check.
    func startTap() {
        guard tap == nil, !suspended else { return }
        if !AXIsProcessTrusted() {
            if !asked { asked = true; askAccessibility() }
            schedulePermissionPoll()
            writeStatus(); refreshIcon()
            return
        }
        let mask = (1 << CGEventType.keyDown.rawValue) | (1 << CGEventType.leftMouseDown.rawValue)
        let me = Unmanaged.passUnretained(self).toOpaque()
        guard let t = CGEvent.tapCreate(tap: .cgSessionEventTap, place: .headInsertEventTap, options: .defaultTap,
                                        eventsOfInterest: CGEventMask(mask), callback: { _, type, ev, ctx in
            Unmanaged<MenuBarApp>.fromOpaque(ctx!).takeUnretainedValue().handle(type, ev)
        }, userInfo: me) else {
            schedulePermissionPoll(every: 30)   // trusted but refused: retry rarely
            writeStatus(); refreshIcon()
            return
        }
        permTimer?.invalidate(); permTimer = nil
        tap = t
        tapSource = CFMachPortCreateRunLoopSource(nil, t, 0)
        CFRunLoopAddSource(CFRunLoopGetMain(), tapSource, .commonModes)
        CGEvent.tapEnable(tap: t, enable: true)
        writeStatus(); refreshIcon()
    }

    func schedulePermissionPoll(every s: TimeInterval = 3) {
        guard permTimer == nil else { return }
        permTimer = Timer.scheduledTimer(withTimeInterval: s, repeats: true) { [weak self] _ in
            guard let self else { return }
            if AXIsProcessTrusted() { self.permTimer?.invalidate(); self.permTimer = nil; self.startTap() }
        }
    }

    /// Fully remove the tap: disable, detach from the run loop, invalidate the port.
    func stopTap() {
        permTimer?.invalidate(); permTimer = nil
        if let t = tap {
            CGEvent.tapEnable(tap: t, enable: false)
            if let src = tapSource { CFRunLoopRemoveSource(CFRunLoopGetMain(), src, .commonModes) }
            CFMachPortInvalidate(t)
        }
        tap = nil; tapSource = nil
        engine?.reset()
    }

    func applicationWillTerminate(_ n: Notification) { stopTap(); writeStatus() }

    func askAccessibility() {
        // a key-changing (non listen-only) event tap needs Accessibility only
        _ = AXIsProcessTrustedWithOptions([kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary)
    }

    /// plain status file so problems can be diagnosed without guessing
    func writeStatus() {
        let s = "tap=\(tap != nil) accessibility=\(AXIsProcessTrusted()) enabled=\(settings.enabled) suspended=\(suspended) breaker=\(engine?.tripped ?? false) ignored=\(settings.ignored.values.sorted()) pid=\(getpid()) at=\(Date())\n"
        DispatchQueue.global(qos: .utility).async {
            try? FileManager.default.createDirectory(at: Settings.dir, withIntermediateDirectories: true)
            try? s.write(to: Settings.dir.appendingPathComponent("status.txt"), atomically: true, encoding: .utf8)
        }
    }

    func handle(_ type: CGEventType, _ ev: CGEvent) -> Unmanaged<CGEvent>? {
        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
            if type == .tapDisabledByTimeout {
                let t = Date()
                timeouts.append(t)
                timeouts.removeAll { t.timeIntervalSince($0) > 300 }
                if timeouts.count >= 3 {
                    // something keeps stalling input: get out of the way until the user resumes
                    DispatchQueue.main.async { [weak self] in
                        self?.suspended = true; self?.stopTap(); self?.writeStatus(); self?.refreshIcon()
                    }
                    return Unmanaged.passUnretained(ev)
                }
            }
            engine.reset()
            if let tap { CGEvent.tapEnable(tap: tap, enable: true) }
            return Unmanaged.passUnretained(ev)
        }
        if type == .leftMouseDown { engine.reset(); return Unmanaged.passUnretained(ev) }
        let tag = ev.getIntegerValueField(.eventSourceUserData)
        if tag == MAGIC { engine.ourEventSeen(); return Unmanaged.passUnretained(ev) }
        if isJustTypeTag(tag) { return Unmanaged.passUnretained(ev) }   // another instance's event
        guard activeHere else { return Unmanaged.passUnretained(ev) }
        let vk = UInt16(ev.getIntegerValueField(.keyboardEventKeycode))
        return engine.handle(vk: vk, flags: ev.flags) == .pass ? Unmanaged.passUnretained(ev) : nil
    }
}
