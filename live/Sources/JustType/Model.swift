import Foundation
import Accelerate

/// Shared tables + weights loaded from Resources/model.json + weights.bin (exported by bench/export.py).
final class ModelFiles {
    let hid: Int, vocab: Int, pad: Int
    let keys: [String]
    let render: [[String]]   // [layout][keyId]
    let tensors: [String: [Float]]

    init(dir: URL) throws {
        let meta = try JSONSerialization.jsonObject(with: Data(contentsOf: dir.appendingPathComponent("model.json"))) as! [String: Any]
        hid = meta["hid"] as! Int; vocab = meta["vocab"] as! Int; pad = meta["pad"] as! Int
        keys = meta["keys"] as! [String]
        render = meta["render"] as! [[String]]
        let data = try Data(contentsOf: dir.appendingPathComponent("weights.bin"))
        let all: [Float] = data.withUnsafeBytes { Array($0.bindMemory(to: Float.self)) }
        var t: [String: [Float]] = [:]
        for d in meta["tensors"] as! [[String: Any]] {
            let shape = d["shape"] as! [Int], off = d["offset"] as! Int
            let n = shape.reduce(1, *)
            t[d["name"] as! String] = Array(all[off..<off + n])
        }
        tensors = t
    }
}

/// 2-layer GRU, one keystroke at a time. Mirrors torch.nn.GRU (gate order r, z, n).
final class KeyGRU {
    let H: Int
    let tab0, whh0, bhh0, wih1, bih1, whh1, bhh1, wout: [Float]
    let bout: Float
    var h0: [Float], h1: [Float]
    private var gi: [Float], gh: [Float]

    init(_ m: ModelFiles) {
        H = m.hid
        tab0 = m.tensors["tab0"]!; whh0 = m.tensors["whh0"]!; bhh0 = m.tensors["bhh0"]!
        wih1 = m.tensors["wih1"]!; bih1 = m.tensors["bih1"]!; whh1 = m.tensors["whh1"]!; bhh1 = m.tensors["bhh1"]!
        wout = m.tensors["wout"]!; bout = m.tensors["bout"]![0]
        h0 = [Float](repeating: 0, count: H); h1 = h0
        gi = [Float](repeating: 0, count: 3 * H); gh = gi
    }

    func reset() { for i in 0..<H { h0[i] = 0; h1[i] = 0 } }

    private func gemv(_ W: [Float], _ x: [Float], _ b: [Float], _ out: inout [Float]) {
        // out = W x + b, W is (3H, H) row-major
        out = b
        W.withUnsafeBufferPointer { w in x.withUnsafeBufferPointer { xp in out.withUnsafeMutableBufferPointer { o in
            cblas_sgemv(CblasRowMajor, CblasNoTrans, Int32(3 * H), Int32(H), 1, w.baseAddress, Int32(H), xp.baseAddress, 1, 1, o.baseAddress, 1)
        }}}
    }

    private func cell(_ h: inout [Float]) {
        for j in 0..<H {
            let r = 1 / (1 + exp(-(gi[j] + gh[j])))
            let z = 1 / (1 + exp(-(gi[H + j] + gh[H + j])))
            let n = tanh(gi[2 * H + j] + r * gh[2 * H + j])
            h[j] = (1 - z) * n + z * h[j]
        }
    }

    /// feed one key id, return P(intended layout = BG)
    func step(_ id: Int) -> Float {
        for j in 0..<(3 * H) { gi[j] = tab0[id * 3 * H + j] }
        gemv(whh0, h0, bhh0, &gh)
        cell(&h0)
        gemv(wih1, h0, bih1, &gi)
        gemv(whh1, h1, bhh1, &gh)
        cell(&h1)
        var s = bout
        for j in 0..<H { s += wout[j] * h1[j] }
        return 1 / (1 + exp(-s))
    }
}
