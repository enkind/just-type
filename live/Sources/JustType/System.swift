import AppKit
import Carbon
import CoreGraphics

let LAYOUT_IDS = ["com.apple.keylayout.US", "com.apple.keylayout.Bulgarian"]
/// Events we inject carry a tag: a JustType prefix + our pid. Our own tag counts as an
/// acknowledgement; another JustType instance's tag is passed through untouched.
let TAG_PREFIX: Int64 = 0x4A55_5354 << 32
let MAGIC: Int64 = TAG_PREFIX | Int64(getpid())
func isJustTypeTag(_ v: Int64) -> Bool { v & ~0xFFFF_FFFF == TAG_PREFIX }

enum Layout {
    static var sources: [TISInputSource] = {
        LAYOUT_IDS.map { id in
            let f = [kTISPropertyInputSourceID as String: id] as CFDictionary
            return (TISCreateInputSourceList(f, true).takeRetainedValue() as! [TISInputSource])[0]
        }
    }()

    static func onMain<T>(_ f: () -> T) -> T { Thread.isMainThread ? f() : DispatchQueue.main.sync(execute: f) }

    static func current() -> Int { onMain { _current() } }

    static func _current() -> Int {
        let src = TISCopyCurrentKeyboardInputSource().takeRetainedValue()
        let id = Unmanaged<CFString>.fromOpaque(TISGetInputSourceProperty(src, kTISPropertyInputSourceID)).takeUnretainedValue() as String
        return id == LAYOUT_IDS[BG] ? BG : EN
    }

    static func select(_ L: Int) {
        onMain { if _current() != L { TISSelectInputSource(sources[L]) } }
    }
}

enum Inject {
    static let src = CGEventSource(stateID: .privateState)

    static func backspaces(_ n: Int) {
        for _ in 0..<n { key(51) }
    }

    static func key(_ vk: CGKeyCode, flags: CGEventFlags = [], magic: Bool = true, source: CGEventSource? = nil) {
        for down in [true, false] {
            let e = CGEvent(keyboardEventSource: source ?? src, virtualKey: vk, keyDown: down)!
            e.flags = flags
            if magic { e.setIntegerValueField(.eventSourceUserData, value: MAGIC) }
            e.post(tap: .cghidEventTap)
        }
    }

    @discardableResult
    static func text(_ s: String) -> Int {
        let u = Array(s.utf16)
        var i = 0, posted = 0
        while i < u.count {
            let chunk = Array(u[i..<min(i + 16, u.count)])
            for down in [true, false] {
                let e = CGEvent(keyboardEventSource: src, virtualKey: 0, keyDown: down)!
                e.flags = []
                chunk.withUnsafeBufferPointer { e.keyboardSetUnicodeString(stringLength: chunk.count, unicodeString: $0.baseAddress) }
                e.setIntegerValueField(.eventSourceUserData, value: MAGIC)
                e.post(tap: .cghidEventTap)
            }
            i += 16
            posted += 1
        }
        return posted
    }
}

func log(_ s: String, to path: String?) {
    guard let path else { FileHandle.standardError.write((s + "\n").data(using: .utf8)!); return }
    let line = (s + "\n").data(using: .utf8)!
    if let h = FileHandle(forWritingAtPath: path) { h.seekToEndOfFile(); h.write(line); h.closeFile() }
    else { FileManager.default.createFile(atPath: path, contents: line) }
}

func permissions(prompt: Bool) -> String {
    if prompt {
        _ = CGRequestListenEventAccess()
        _ = CGRequestPostEventAccess()
        _ = AXIsProcessTrustedWithOptions([kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary)
    }
    return "accessibility=\(AXIsProcessTrusted()) input_monitoring=\(CGPreflightListenEventAccess()) post=\(CGPreflightPostEventAccess())"
}
