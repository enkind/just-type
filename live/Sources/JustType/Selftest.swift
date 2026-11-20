import CoreGraphics
import Foundation

/// Replays episodes through the real Engine with a fake OS that (a) delays layout switches
/// and (b) lets the user's next key arrive before our injected corrections. The final text
/// must match the Python simulator's prediction in every scenario.
final class FakeOS: Sink {
    let keys: Keys
    var actual = 0
    var pendingSelect: (L: Int, after: Int)?
    var lag = 0
    enum Ev { case user(vk: UInt16, flags: CGEventFlags, sel: Int?), back, text(String), repost }
    var queue: [Ev] = []
    var buf: [Character] = []

    init(keys: Keys) { self.keys = keys }
    func backspaces(_ n: Int) -> Int { for _ in 0..<n { queue.append(.back) }; return n }
    func text(_ s: String) -> Int { if s.isEmpty { return 0 }; queue.append(.text(s)); return 1 }
    func repost(vk: UInt16, flags: CGEventFlags) -> Int { queue.append(.repost); return 1 }
    func select(_ L: Int) { if lag == 0 { actual = L } else { pendingSelect = (L, lag) } }
    func current() -> Int { actual }

    func tick() {
        if let p = pendingSelect {
            if p.after <= 1 { actual = p.L; pendingSelect = nil } else { pendingSelect = (p.L, p.after - 1) }
        }
    }
}

func selftest(model: ModelFiles, cfg: Config, episodesPath: String, expectedPath: String) -> String {
    let eps = loadEpisodes(episodesPath)
    let expected = loadEpisodes(expectedPath)
    let exp = Dictionary(uniqueKeysWithValues: expected.map { ($0["id"] as! Int, $0) })
    var report: [String] = []
    for (lag, race, undoAll) in [(0, 0.0, false), (3, 0.0, false), (0, 0.8, false), (3, 0.8, false), (0, 0.0, true), (0, 0.8, true), (3, 0.8, true)] {
        var ok = 0, fails: [String] = []
        var rng = SystemRandomNumberGenerator()
        for ep in eps {
            let id = ep["id"] as! Int
            let fake = FakeOS(keys: Keys(model))
            fake.lag = lag
            let engine = Engine(det: Detector(model, cfg: cfg), sink: fake)
            var clock = Date(timeIntervalSince1970: 0)
            engine.now = { clock }
            var fixed = false
            engine.onFix = { o, _ in if o != "undo" { fixed = true } }
            fake.actual = ep["init"] as! Int
            let sel = ep["user_sel"] as! [String: Int]
            var user: [FakeOS.Ev] = (ep["keys"] as! [Int]).enumerated().map { i, k in
                let vk: UInt16 = k == 94 ? 49 : Keys.codesByKey[k / 2]
                return .user(vk: vk, flags: (k != 94 && k % 2 == 1) ? .maskShift : [], sel: sel[String(i)])
            }
            user.append(.user(vk: 49, flags: [], sel: nil))  // trailing space, like the live harness
            var ui = 0
            while ui < user.count || !fake.queue.isEmpty {
                if fake.queue.isEmpty { fake.queue.append(user[ui]); ui += 1; clock += 0.07 }
                let ev = fake.queue.removeFirst()
                fake.tick()
                switch ev {
                case let .user(vk, flags, s):
                    if let s { fake.actual = s; fake.pendingSelect = nil }
                    let before = fake.queue.count
                    fixed = false
                    if engine.handle(vk: vk, flags: flags) == .pass {
                        if vk == 51 { if !fake.buf.isEmpty { fake.buf.removeLast() } }
                        else if let k = fake.keys.id(vk: vk, shift: flags.contains(.maskShift)) {
                            fake.buf.append(contentsOf: fake.keys.render[fake.actual][k])
                        }
                    }
                    if undoAll && fixed {
                        fake.queue.insert(.user(vk: 6, flags: .maskCommand, sel: nil), at: before)
                    } else if fake.queue.count > before && ui < user.count && Double.random(in: 0..<1, using: &rng) < race {
                        fake.queue.insert(user[ui], at: before); ui += 1; clock += 0.03
                    }
                case .back: engine.ourEventSeen(); if !fake.buf.isEmpty { fake.buf.removeLast() }
                case let .text(s): engine.ourEventSeen(); fake.buf.append(contentsOf: s)
                case .repost: engine.ourEventSeen()
                }
            }
            let got = String(fake.buf).trimmingCharacters(in: .init(charactersIn: " "))
            let want = exp[id]![undoAll ? "base" : "justtype"] as! String
            if got == want { ok += 1 } else if fails.count < 3 { fails.append("#\(id) got «\(got.prefix(90))» want «\(want.prefix(90))»") }
        }
        report.append("lag=\(lag) race=\(race) undoAll=\(undoAll): \(ok)/\(eps.count) match" + (fails.isEmpty ? "" : "\n   " + fails.joined(separator: "\n   ")))
    }
    return report.joined(separator: "\n")
}

/// Safety tests: (1) a feedback loop where every injected event comes back as a fresh,
/// untagged user keystroke must trip the circuit breaker quickly with bounded output;
/// (2) a 200-key token without spaces must never cause a large delete/retype burst.
func safetyTest(model: ModelFiles, cfg: Config) -> String {
    var out: [String] = []
    // (1) feedback loop
    do {
        let fake = FakeOS(keys: Keys(model))
        let engine = Engine(det: Detector(model, cfg: cfg), sink: fake)
        var clock = Date(timeIntervalSince1970: 0)
        engine.now = { clock }
        fake.actual = EN
        // "също нали" typed on the US layout, i.e. wrong layout -> guaranteed fixes
        let start: [UInt16] = [34, 8, 16, 3, 49, 40, 3, 40, 11, 49]
        for vk in start { fake.queue.append(.user(vk: vk, flags: [], sel: nil)) }
        var injectedTotal = 0, delivered = 0
        while !fake.queue.isEmpty && delivered < 100_000 {
            let ev = fake.queue.removeFirst(); delivered += 1; clock += 0.005
            switch ev {
            case let .user(vk, flags, _): _ = engine.handle(vk: vk, flags: flags)
            case .back, .text, .repost:
                injectedTotal += 1
                // the hostile part: our own output comes back as a NEW untagged keystroke
                fake.queue.append(.user(vk: [34, 8, 16, 3, 49].randomElement()!, flags: [], sel: nil))
            }
        }
        out.append("feedback loop: tripped=\(engine.tripped) injected=\(injectedTotal) delivered=\(delivered) "
                   + (engine.tripped && injectedTotal < 400 && delivered < 100_000 ? "OK" : "FAIL"))
    }
    // (2) giant token
    do {
        let fake = FakeOS(keys: Keys(model))
        let engine = Engine(det: Detector(model, cfg: cfg), sink: fake)
        var clock = Date(timeIntervalSince1970: 0)
        engine.now = { clock }
        fake.actual = EN
        var maxBurst = 0
        let vks: [UInt16] = [34, 8, 16, 3, 40, 11, 2, 45, 31, 37]   // Bulgarian letters typed on US keys
        for i in 0..<200 {
            clock += 0.07
            let before = fake.queue.count
            _ = engine.handle(vk: vks[i % vks.count], flags: [])
            var burst = 0
            for e in fake.queue[before...] {
                switch e { case .back: burst += 1; case let .text(s): burst += s.count; default: break }
            }
            maxBurst = max(maxBurst, burst)
            fake.queue.removeAll()
        }
        out.append("giant token: max single burst = \(maxBurst) chars " + (maxBurst <= 2 * Detector.maxToken + 2 ? "OK" : "FAIL"))
    }
    return out.joined(separator: "\n")
}
