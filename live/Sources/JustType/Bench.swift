import AppKit
import CoreGraphics

/// Typing harness: a window with a plain text view; types each episode's keystrokes at
/// human speed via CGEvent (as if from the keyboard), applies the episode's layout
/// selections, then records what ended up in the text view.
final class Bench: NSObject, NSApplicationDelegate {
    let episodes: [[String: Any]]
    let outPath: String, label: String
    let minMs: Double, maxMs: Double
    var window: NSWindow!, textView: NSTextView!
    var abort = false
    let hidSrc = CGEventSource(stateID: .hidSystemState)

    init(episodes: [[String: Any]], outPath: String, label: String, minMs: Double, maxMs: Double) {
        self.episodes = episodes; self.outPath = outPath; self.label = label; self.minMs = minMs; self.maxMs = maxMs
    }

    func applicationDidFinishLaunching(_ n: Notification) {
        window = NSWindow(contentRect: NSRect(x: 200, y: 200, width: 1000, height: 420), styleMask: [.titled, .closable],
                          backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.title = "TypeBench — \(label)  (Esc aborts; don't touch the keyboard/mouse)"
        let sv = NSTextView.scrollableTextView()
        sv.frame = window.contentView!.bounds
        sv.autoresizingMask = [.width, .height]
        textView = (sv.documentView as! NSTextView)
        textView.font = NSFont.systemFont(ofSize: 18)
        textView.isAutomaticQuoteSubstitutionEnabled = false
        textView.isAutomaticDashSubstitutionEnabled = false
        textView.isAutomaticSpellingCorrectionEnabled = false
        textView.isAutomaticTextReplacementEnabled = false
        textView.isContinuousSpellCheckingEnabled = false
        textView.isAutomaticLinkDetectionEnabled = false
        textView.isAutomaticDataDetectionEnabled = false
        textView.isAutomaticTextCompletionEnabled = false
        textView.smartInsertDeleteEnabled = false
        textView.isGrammarCheckingEnabled = false
        window.contentView!.addSubview(sv)
        window.makeKeyAndOrderFront(nil)
        window.makeFirstResponder(textView)
        NSApp.activate(ignoringOtherApps: true)
        NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] e in
            if e.keyCode == 53 { self?.abort = true; return nil }
            return e
        }
        DispatchQueue.global().asyncAfter(deadline: .now() + 1.5) { self.runAll() }
    }

    func ms(_ x: Double) { usleep(useconds_t(x * 1000)) }

    func ensureFront() -> Bool {
        if !DispatchQueue.main.sync(execute: { window.isVisible }) { return false }
        DispatchQueue.main.sync {
            if !NSApp.isActive { NSApp.activate(ignoringOtherApps: true); window.makeKeyAndOrderFront(nil) }
            window.makeFirstResponder(textView)
        }
        for _ in 0..<20 {
            if DispatchQueue.main.sync(execute: { NSApp.isActive && window.isKeyWindow }) { return true }
            ms(100)
        }
        return false
    }

    func type(_ id: Int) {
        let space = 94
        let vk: CGKeyCode = id == space ? 49 : Keys.codesByKey[id / 2]
        let shift = id != space && id % 2 == 1
        if shift { post(56, down: true, flags: .maskShift) }
        post(vk, down: true, flags: shift ? .maskShift : [])
        ms(Double.random(in: 15...35))
        post(vk, down: false, flags: shift ? .maskShift : [])
        if shift { post(56, down: false, flags: []) }
    }

    func post(_ vk: CGKeyCode, down: Bool, flags: CGEventFlags) {
        let e = CGEvent(keyboardEventSource: hidSrc, virtualKey: vk, keyDown: down)!
        e.flags = flags
        e.post(tap: .cghidEventTap)
    }

    func runAll() {
        log("bench start label=\(label) n=\(episodes.count)", to: outPath + ".log")
        for ep in episodes {
            if abort { break }
            guard ensureFront() else { log("lost focus, stopping", to: outPath + ".log"); break }
            DispatchQueue.main.sync { textView.string = "" }
            let keys = ep["keys"] as! [Int]
            let sel = ep["user_sel"] as! [String: Int]
            Layout.select(ep["init"] as! Int)
            ms(400)
            let t0 = Date()
            for (i, k) in keys.enumerated() {
                if abort { break }
                if let L = sel[String(i)] { Layout.select(L); ms(60) }
                type(k)
                ms(Double.random(in: minMs...maxMs))
            }
            type(94)          // trailing space = word boundary for the last word
            ms(900)           // let tools finish their corrections
            let final = DispatchQueue.main.sync { textView.string }
            let rec: [String: Any] = ["id": ep["id"]!, "tool": label, "final": final,
                                      "seconds": Date().timeIntervalSince(t0), "aborted": abort]
            let d = try! JSONSerialization.data(withJSONObject: rec)
            log(String(data: d, encoding: .utf8)!, to: outPath)
        }
        log("bench done", to: outPath + ".log")
        DispatchQueue.main.async { NSApp.terminate(nil) }
    }
}
