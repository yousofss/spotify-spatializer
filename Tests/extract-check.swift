// Round-trip check for extractIR: synthesize a Fixed pass from known paths and make sure
// they come back out at the right gain and relative delay.
//
//   swiftc -O -parse-as-library Sources/Engine.swift Sources/Measure.swift Tests/extract-check.swift -o /tmp/extract-check && /tmp/extract-check

import Foundation

@main struct ExtractCheck {
    static func main() throws {
        let x = measurementSignal
        let latency = 700
        let paths: [(delay: Int, gain: Float, from: Int, to: Int)] = [
            (100, 0.8, 0, 0), (130, 0.3, 0, 1), (120, 0.25, 1, 0), (95, 0.7, 1, 1),  // LL LR RL RR
        ]
        var fixed = [Float](repeating: 0, count: x.count + 2 * (latency + 200))
        var off = fixed
        for i in 0..<(x.count / 2) {
            off[2 * (i + latency)] = x[2 * i]
            off[2 * (i + latency) + 1] = x[2 * i + 1]
            for p in paths { fixed[2 * (i + latency + p.delay) + p.to] += p.gain * x[2 * i + p.from] }
        }

        let data = try extractIR(fixed: fixed, off: off)
        let irLen = Int(data.withUnsafeBytes { $0.loadUnaligned(fromByteOffset: 8, as: UInt32.self) })
        for (k, p) in paths.enumerated() {
            let at = 256 + p.delay - paths[0].delay  // window starts 256 taps before the LL peak
            let got = data.withUnsafeBytes { $0.loadUnaligned(fromByteOffset: 12 + (k * irLen + at) * 4, as: Float.self) }
            precondition(abs(got - p.gain) < 0.02, "path \(k): expected \(p.gain) at tap \(at), got \(got)")
        }

        do {
            _ = try extractIR(fixed: off, off: off)
            preconditionFailure("an unspatialized pass must be rejected")
        } catch {}
        print("ok")
    }
}
