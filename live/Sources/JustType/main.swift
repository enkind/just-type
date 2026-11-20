import AppKit
import Foundation

// Modes:
//   check  [out]                         write permission status (and prompt for missing ones)
//   sim    episodes.jsonl out.json       parity test: Swift GRU probs vs exported Python probs
//   app (default)                        menu-bar app: event tap + ignore list
//   selftest episodes.jsonl expected.jsonl   engine vs simulator under delays / reordering
//   bench  episodes.jsonl out.jsonl label [minMs maxMs limit]   typing harness
let args = CommandLine.arguments
// model files live outside the (signed) bundle so re-exporting them keeps macOS permissions
let devRes = Bundle.main.bundleURL.deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("Resources")
let mode = args.count > 1 && !args[1].hasPrefix("-") ? args[1] : "app"
// model files: inside the app bundle when installed, else live/Resources during development
let res: URL = FileManager.default.fileExists(atPath: Bundle.main.resourceURL!.appendingPathComponent("weights.bin").path)
    ? Bundle.main.resourceURL! : devRes

func loadEpisodes(_ p: String) -> [[String: Any]] {
    try! String(contentsOfFile: p, encoding: .utf8).split(separator: "\n").map {
        try! JSONSerialization.jsonObject(with: Data($0.utf8)) as! [String: Any]
    }
}

switch mode {
case "check":
    let s = permissions(prompt: true)
    if args.count > 2 { try? s.write(toFile: args[2], atomically: true, encoding: .utf8) } else { print(s) }
case "sim":
    let m = try! ModelFiles(dir: res)
    let gru = KeyGRU(m)
    var maxDiff: Float = 0, n = 0
    let t0 = Date()
    for ep in loadEpisodes(args[2]) {
        gru.reset()
        let ps = ep["p_bg"] as! [Double]
        for (i, k) in (ep["keys"] as! [Int]).enumerated() {
            let p = gru.step(k)
            maxDiff = max(maxDiff, abs(p - Float(ps[i]))); n += 1
        }
    }
    let us = Date().timeIntervalSince(t0) / Double(n) * 1e6
    let out = "{\"keys\": \(n), \"max_abs_diff\": \(maxDiff), \"us_per_key\": \(us)}"
    if args.count > 3 { try! out.write(toFile: args[3], atomically: true, encoding: .utf8) } else { print(out) }
case "app":
    // single instance per user: a second copy exits immediately (exit 0 = launchd won't respawn it)
    try? FileManager.default.createDirectory(at: Settings.dir, withIntermediateDirectories: true)
    let lockFD = open(Settings.dir.appendingPathComponent("instance.lock").path, O_CREAT | O_RDWR, 0o600)
    if lockFD < 0 || flock(lockFD, LOCK_EX | LOCK_NB) != 0 {
        FileHandle.standardError.write("JustType is already running\n".data(using: .utf8)!)
        exit(0)
    }
    let m = try! ModelFiles(dir: res)
    let app = NSApplication.shared
    app.setActivationPolicy(.accessory)
    let delegate = MenuBarApp(model: m, cfg: Config())
    app.delegate = delegate   // NSApplication.delegate is weak: keep ours alive for the app's lifetime
    // launchctl bootout / kill: remove the tap before exiting
    var signalSources: [DispatchSourceSignal] = []
    for sig in [SIGTERM, SIGINT, SIGHUP] {
        signal(sig, SIG_IGN)
        let src = DispatchSource.makeSignalSource(signal: sig, queue: .main)
        src.setEventHandler { delegate.stopTap(); exit(0) }
        src.resume()
        signalSources.append(src)
    }
    withExtendedLifetime((delegate, signalSources, lockFD)) { app.run() }
case "selftest":
    let m = try! ModelFiles(dir: res)
    print(selftest(model: m, cfg: Config(), episodesPath: args[2], expectedPath: args[3]))
    print(safetyTest(model: m, cfg: Config()))
case "bench":
    var eps = loadEpisodes(args[2])
    if args.count > 7 { eps = Array(eps.prefix(Int(args[7])!)) }
    if args.count > 8 { eps = Array(eps.dropFirst(Int(args[8])!)) }   // resume from episode index
    let app = NSApplication.shared
    app.setActivationPolicy(.regular)
    let b = Bench(episodes: eps, outPath: args[3], label: args[4],
                  minMs: args.count > 5 ? Double(args[5])! : 50, maxMs: args.count > 6 ? Double(args[6])! : 110)
    app.delegate = b
    withExtendedLifetime(b) { app.run() }
default:
    print("unknown mode")
}
