import Foundation

let EN = 0, BG = 1

/// Physical key <-> key id, and per-layout rendering. Key id = keyIndex*2 + shift; space = 94.
final class Keys {
    let render: [[String]]
    let spaceId: Int
    var vkToKey: [UInt16: Int] = [:]
    let neutral: [Bool]

    init(_ m: ModelFiles) {
        render = m.render
        spaceId = m.keys.count * 2
        // ANSI virtual keycodes for the US keys in "`1234567890-=qwertyuiop[]\asdfghjkl;'zxcvbnm,./" order
        let order = Array("`1234567890-=qwertyuiop[]\\asdfghjkl;'zxcvbnm,./").map(String.init)
        let codes: [UInt16] = [50,18,19,20,21,23,22,26,28,25,29,27,24,12,13,14,15,17,16,32,34,31,35,33,30,42,0,1,2,3,5,4,38,40,37,41,39,6,7,8,9,11,45,46,43,47,44]
        for (i, name) in m.keys.enumerated() {
            if let j = order.firstIndex(of: name) { vkToKey[codes[j]] = i }
        }
        neutral = (0..<m.vocab).map { m.render[0][$0] == m.render[1][$0] }
    }

    static let codesByKey: [UInt16] = [50,18,19,20,21,23,22,26,28,25,29,27,24,12,13,14,15,17,16,32,34,31,35,33,30,42,0,1,2,3,5,4,38,40,37,41,39,6,7,8,9,11,45,46,43,47,44]

    func id(vk: UInt16, shift: Bool) -> Int? {
        if vk == 49 { return spaceId }
        guard let k = vkToKey[vk] else { return nil }
        return k * 2 + (shift ? 1 : 0)
    }

    func text(_ ids: [Int], _ lays: [Int]) -> String { zip(ids, lays).map { render[$1][$0] }.joined() }
    func text(_ ids: [Int], _ L: Int) -> String { ids.map { render[L][$0] }.joined() }
}

struct Config: Codable {
    var te: Float = 0.8       // fire at word end when P(wrong) >= te
    var tm: Float = 0.995     // fire mid-word when P(wrong) >= tm ...
    var nmin: Int = 4         // ... and at least nmin layout-dependent keys typed
}

enum Action {
    case pass
    /// delete `delete` chars, insert `insert`, then switch to `layout`; the triggering key is swallowed.
    /// `original` is what the user's keys would have produced without the fix (for undo).
    case fix(delete: Int, insert: String, original: String, layout: Int, boundary: Bool)
}

/// The online policy; same logic as bench/model.py ModelTool.
final class Detector {
    let gru: KeyGRU, keys: Keys
    var cfg: Config
    var tokKeys: [Int] = [], tokLays: [Int] = []
    var fired = false
    var lastP: Float = 0.5
    /// longer tokens are never corrected (URLs, pasted junk): bounds per-key work and burst size
    static let maxToken = 40
    var overflow = false

    init(_ m: ModelFiles, cfg: Config) { gru = KeyGRU(m); keys = Keys(m); self.cfg = cfg }

    func reset() { gru.reset(); breakToken() }
    func breakToken() { tokKeys = []; tokLays = []; fired = false; overflow = false }
    /// user undid the last fix: the current token (if the fix was mid-word) is back in `prev`
    func undo(prev: Int, boundary: Bool) {
        if !boundary { tokLays = tokLays.map { _ in prev } }
    }

    func backspace() { if !tokKeys.isEmpty { tokKeys.removeLast(); tokLays.removeLast() } }

    func key(_ id: Int, active: Int) -> Action {
        let p = gru.step(id)
        lastP = p
        let pw = active == EN ? p : 1 - p
        if id == keys.spaceId {
            defer { breakToken() }
            if tokKeys.isEmpty || fired || overflow || pw < cfg.te { return .pass }
            if !tokKeys.contains(where: { !keys.neutral[$0] }) { return .pass }
            let orig = keys.text(tokKeys, tokLays)
            return .fix(delete: orig.count, insert: keys.text(tokKeys, 1 - active) + " ", original: orig + " ",
                        layout: 1 - active, boundary: true)
        }
        if overflow || tokKeys.count >= Detector.maxToken { overflow = true; return .pass }
        let del = keys.text(tokKeys, tokLays).count
        tokKeys.append(id); tokLays.append(active)
        let n = tokKeys.filter { !keys.neutral[$0] }.count
        if !fired && n >= cfg.nmin && pw >= cfg.tm {
            fired = true
            let ins = keys.text(tokKeys, 1 - active)
            let orig = keys.text(tokKeys, tokLays)
            tokLays = tokLays.map { _ in 1 - active }
            return .fix(delete: del, insert: ins, original: orig, layout: 1 - active, boundary: false)
        }
        return .pass
    }
}
