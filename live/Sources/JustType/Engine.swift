import CoreGraphics
import Foundation

/// Where the engine's corrections go. The real one posts CGEvents and calls TIS;
/// the self-test uses a fake that simulates delays and out-of-order delivery.
protocol Sink: AnyObject {
    /// each returns how many keyDown events it posted (they come back through the tap marked as ours)
    func backspaces(_ n: Int) -> Int
    func text(_ s: String) -> Int
    func repost(vk: UInt16, flags: CGEventFlags) -> Int
    func select(_ L: Int)
    func current() -> Int
}

enum Verdict { case pass, swallow }

/// Turns key events into decisions. Ordering-safe: after a fix, until our own injected
/// events have come back through the tap and the layout switch has really taken effect,
/// the user's keys are swallowed and re-injected in order, rendered in the target layout.
final class Engine {
    let det: Detector
    unowned let sink: Sink
    var now: () -> Date = Date.init
    var onFix: ((String, String) -> Void)?   // (original, inserted) for the optional log

    private var target: Int?
    private var landed = false   // our layout switch has visibly taken effect
    private var softUntil = Date.distantPast, hardUntil = Date.distantPast
    private var pending = 0
    private var lastFix: (ins: Int, orig: String, prev: Int, boundary: Bool, at: Date)?

    // circuit breaker: a runaway loop (e.g. another tool feeding our output back) shows up as
    // many fixes or many injected events per second; normal typing can't get anywhere near.
    private var recentFixes: [Date] = []
    private var recentInjected: [(Date, Int)] = []
    private(set) var trippedUntil = Date.distantPast
    var onTrip: (() -> Void)?
    var tripped: Bool { now() < trippedUntil }

    private func injected(_ n: Int) -> Int {
        guard n > 0 else { return 0 }
        let t = now()
        recentInjected.append((t, n))
        recentInjected.removeAll { t.timeIntervalSince($0.0) > 2 }
        // > 300 events/s, or > 120 separate injections within 2 s (a fix is 2, a re-injected
        // keystroke 1; real typing with every word fixed stays well under that)
        let lastSecond = recentInjected.filter { t.timeIntervalSince($0.0) <= 1 }.reduce(0) { $0 + $1.1 }
        if lastSecond > 300 || recentInjected.count > 120 { trip() }
        return n
    }

    private func noteFix() {
        let t = now()
        recentFixes.append(t)
        recentFixes.removeAll { t.timeIntervalSince($0) > 1 }
        if recentFixes.count > 8 { trip() }
    }

    private func trip() {
        trippedUntil = now().addingTimeInterval(60)
        target = nil; pending = 0; lastFix = nil
        det.breakToken()
        onTrip?()
    }

    init(det: Detector, sink: Sink) { self.det = det; self.sink = sink }

    func ourEventSeen() { pending = max(0, pending - 1) }

    func reset() {
        det.reset(); target = nil; pending = 0; lastFix = nil
    }

    private func startTakeover(_ L: Int) {
        target = L
        landed = sink.current() == L   // TIS switches are usually synchronous
        softUntil = now().addingTimeInterval(0.25)
        hardUntil = now().addingTimeInterval(0.6)
    }

    private var inTakeover: Bool {
        guard let t = target else { return false }
        let n = now()
        let cur = sink.current()
        if cur == t { landed = true }
        // the user switched layout themselves after ours landed: follow their choice
        // (still re-injecting in order while our corrections are in flight)
        if landed && cur != t { target = cur; return self.inTakeover }
        // never hand control back while our own corrections are still in flight; that's what
        // reorders text. The 3 s cutoff only guards against an injected event getting lost.
        if n > hardUntil.addingTimeInterval(2.4) { pending = 0; target = nil; return false }
        if pending == 0 && ((n >= softUntil && cur == t) || n > hardUntil) {
            target = nil
            return false
        }
        return true
    }

    func handle(vk: UInt16, flags: CGEventFlags) -> Verdict {
        if tripped && target == nil { return .pass }
        let undoable = lastFix
        lastFix = nil
        let cmd = flags.contains(.maskCommand), ctl = flags.contains(.maskControl), opt = flags.contains(.maskAlternate)
        if cmd || ctl || opt {
            // ⌘Z right after a fix: put the original text and layout back
            if cmd && !ctl && !opt && vk == 6, let f = undoable, now().timeIntervalSince(f.at) < 5 {
                pending += injected(sink.backspaces(f.ins))
                pending += injected(sink.text(f.orig))
                sink.select(f.prev)
                startTakeover(f.prev)
                det.undo(prev: f.prev, boundary: f.boundary)
                onFix?("undo", f.orig)
                return .swallow
            }
            det.breakToken()
            return .pass
        }
        let takeover = inTakeover
        if vk == 51 {  // backspace
            det.backspace()
            if takeover { pending += injected(sink.backspaces(1)); return .swallow }
            return .pass
        }
        guard let id = det.keys.id(vk: vk, shift: flags.contains(.maskShift)) else {
            det.breakToken()  // return, tab, arrows, ...
            if takeover { pending += injected(sink.repost(vk: vk, flags: flags)); return .swallow }
            return .pass
        }
        let active = takeover ? (target ?? sink.current()) : sink.current()
        switch det.key(id, active: active) {
        case .pass:
            if takeover { pending += injected(sink.text(det.keys.render[active][id])); return .swallow }
            return .pass
        case let .fix(del, ins, orig, layout, boundary):
            if tripped {  // breaker open: never correct, just let the key through
                det.breakToken()
                return takeover ? .swallow : .pass
            }
            noteFix()
            pending += injected(sink.backspaces(del))
            pending += injected(sink.text(ins))
            sink.select(layout)
            startTakeover(layout)
            lastFix = (ins.count, orig, active, boundary, now())
            onFix?(orig, ins)
            return .swallow
        }
    }
}
