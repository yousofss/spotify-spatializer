// extract-ir.swift — recover Apple's fixed-mode spatializer impulse responses from the
// sweep recordings made with record-tap + sweep.mov.
//
//   swiftc -O extract-ir.swift -o extract-ir
//   ./extract-ir fixed.wav off.wav irs.bin
//
// Deconvolves the left-only and right-only log sweeps (Farina method, regularized
// spectral division) into the four paths LL, LR, RL, RR (input→output), normalized so
// that the Off recording is the unity reference. Output: irs.bin ('SIR1', fs, irLen,
// then 4×irLen float32).

import Accelerate
import Foundation

let args = CommandLine.arguments
let fixedPath = args.count > 1 ? args[1] : "fixed.wav"
let offPath = args.count > 2 ? args[2] : "off.wav"
let outPath = args.count > 3 ? args[3] : "irs.bin"

func die(_ msg: String) -> Never {
    FileHandle.standardError.write(Data("error: \(msg)\n".utf8))
    exit(1)
}

func loadWav(_ path: String) -> (left: [Float], right: [Float], rate: Int) {
    guard let d = FileManager.default.contents(atPath: path) else { die("cannot read \(path)") }
    var i = 12, rate = 0, interleaved = [Float]()
    while i + 8 <= d.count {
        let cid = String(decoding: d[i..<i+4], as: UTF8.self)
        let size = d[i+4..<i+8].withUnsafeBytes { $0.loadUnaligned(as: UInt32.self) }
        if cid == "fmt " {
            let fmt = d[i+8..<i+10].withUnsafeBytes { $0.loadUnaligned(as: UInt16.self) }
            let ch = d[i+10..<i+12].withUnsafeBytes { $0.loadUnaligned(as: UInt16.self) }
            rate = Int(d[i+12..<i+16].withUnsafeBytes { $0.loadUnaligned(as: UInt32.self) })
            guard fmt == 3, ch == 2 else { die("\(path): expected float32 stereo") }
        } else if cid == "data" {
            let n = Int(size) / 4
            interleaved = [Float](repeating: 0, count: n)
            _ = interleaved.withUnsafeMutableBytes { d.copyBytes(to: $0, from: (i+8)..<(i+8+Int(size))) }
        }
        i += 8 + Int(size) + (Int(size) & 1)
    }
    guard !interleaved.isEmpty, rate == 48000 else { die("\(path): no data or not 48kHz") }
    let frames = interleaved.count / 2
    var l = [Float](repeating: 0, count: frames), r = l
    for j in 0..<frames { l[j] = interleaved[2*j]; r[j] = interleaved[2*j+1] }
    return (l, r, rate)
}

// Source signal layout (must match make-sweep.swift exactly)
let sr = 48000
let sweepLen = 6 * sr
let click1 = 48000
let lSweepStart = 124803  // 48000 + 3*(1+14400) + 33600
let rSweepStart = lSweepStart + sweepLen + sr

func makeSweep() -> [Float] {
    var x = [Float](repeating: 0, count: sweepLen)
    let f1 = 40.0, f2 = 18000.0
    let L = 6.0 / log(f2 / f1)
    let K = 2 * Double.pi * f1 * L
    for i in 0..<sweepLen {
        let t = Double(i) / Double(sr)
        x[i] = Float(0.5 * sin(K * (exp(t / L) - 1)))
    }
    return x
}

func firstClick(_ l: [Float], _ r: [Float]) -> Int {
    for i in 0..<l.count where abs(l[i]) + abs(r[i]) > 0.05 { return i }
    die("no click found")
}

// MARK: - FFT deconvolution

let log2N = 20
let N = 1 << log2N
guard let fft = vDSP_create_fftsetup(vDSP_Length(log2N), FFTRadix(kFFTRadix2)) else { die("fft setup") }

func forwardFFT(_ x: [Float]) -> (re: [Float], im: [Float]) {
    var re = [Float](repeating: 0, count: N / 2), im = re
    var padded = x
    padded.append(contentsOf: [Float](repeating: 0, count: N - x.count))
    re.withUnsafeMutableBufferPointer { rb in
        im.withUnsafeMutableBufferPointer { ib in
            var split = DSPSplitComplex(realp: rb.baseAddress!, imagp: ib.baseAddress!)
            padded.withUnsafeBytes {
                vDSP_ctoz($0.baseAddress!.assumingMemoryBound(to: DSPComplex.self), 2, &split, 1, vDSP_Length(N / 2))
            }
            vDSP_fft_zrip(fft, &split, 1, vDSP_Length(log2N), FFTDirection(FFT_FORWARD))
        }
    }
    return (re, im)
}

/// h = IFFT( Y·X* / (|X|²+λ) ), handling vDSP's packed DC/Nyquist in bin 0.
func deconvolve(_ y: [Float], _ x: (re: [Float], im: [Float]), _ lambda: Float) -> [Float] {
    let Y = forwardFFT(y)
    var re = [Float](repeating: 0, count: N / 2), im = re
    for k in 1..<(N / 2) {
        let xr = x.re[k], xi = x.im[k], yr = Y.re[k], yi = Y.im[k]
        let denom = xr * xr + xi * xi + lambda
        re[k] = (yr * xr + yi * xi) / denom
        im[k] = (yi * xr - yr * xi) / denom
    }
    re[0] = Y.re[0] * x.re[0] / (x.re[0] * x.re[0] + lambda)  // DC (real)
    im[0] = Y.im[0] * x.im[0] / (x.im[0] * x.im[0] + lambda)  // Nyquist (real)
    var h = [Float](repeating: 0, count: N)
    re.withUnsafeMutableBufferPointer { rb in
        im.withUnsafeMutableBufferPointer { ib in
            var split = DSPSplitComplex(realp: rb.baseAddress!, imagp: ib.baseAddress!)
            vDSP_fft_zrip(fft, &split, 1, vDSP_Length(log2N), FFTDirection(FFT_INVERSE))
            h.withUnsafeMutableBytes {
                vDSP_ztoc(&split, 1, $0.baseAddress!.assumingMemoryBound(to: DSPComplex.self), 2, vDSP_Length(N / 2))
            }
        }
    }
    var scale = Float(1) / (2 * Float(N))  // zrip forward+inverse round trip gains 2N... times 2 from packing
    vDSP_vsmul(h, 1, &scale, &h, 1, vDSP_Length(N))
    return h
}

// MARK: - run

let fixed = loadWav(fixedPath)
let off = loadWav(offPath)
let sweep = makeSweep()

// Self-calibrate the FFT scale convention: deconvolve the sweep against itself; the
// result must be a unit impulse at 0. Whatever it actually is becomes the divisor.
let X = forwardFFT(sweep)
var mx: Float = 0
vDSP_maxmgv(X.re, 1, &mx, vDSP_Length(N / 2))
let lambda = (1e-4 * mx) * (1e-4 * mx)
let selfTest = deconvolve(sweep, X, lambda)
let unit = selfTest[0]
print("self-test impulse: \(unit) (using as scale reference)")

let pre = 4800
let segLen = sweepLen + 48000 + pre

func segment(_ ch: [Float], _ clickAt: Int, _ sourceStart: Int) -> [Float] {
    let start = clickAt + (sourceStart - click1) - pre
    guard start >= 0, start + segLen <= ch.count else { die("recording too short for segment") }
    return Array(ch[start..<(start + segLen)])
}

// Reference gain from the Off pass (whole chain at unity spatialization)
let offClick = firstClick(off.left, off.right)
let offH = deconvolve(segment(off.left, offClick, lSweepStart), X, lambda)
var offPeak: Float = 0
var offPeakIdx: vDSP_Length = 0
vDSP_maxmgvi(offH, 1, &offPeak, &offPeakIdx, vDSP_Length(pre + 2 * sr))
let g0 = offH[Int(offPeakIdx)] / unit
print("off-pass reference: gain \(String(format: "%.4f", g0)) (\(String(format: "%.1f", 20 * log10(abs(g0)))) dB) at lag \(Int(offPeakIdx) - pre)")

let fxClick = firstClick(fixed.left, fixed.right)
let hLL = deconvolve(segment(fixed.left, fxClick, lSweepStart), X, lambda)
let hLR = deconvolve(segment(fixed.right, fxClick, lSweepStart), X, lambda)
let hRL = deconvolve(segment(fixed.left, fxClick, rSweepStart), X, lambda)
let hRR = deconvolve(segment(fixed.right, fxClick, rSweepStart), X, lambda)

// One shared window keeps inter-path timing intact: anchor on the LL direct peak.
var peak: Float = 0
var peakIdx: vDSP_Length = 0
vDSP_maxmgvi(hLL, 1, &peak, &peakIdx, vDSP_Length(pre + 2 * sr))
let w = max(Int(peakIdx) - 256, 0)
let irLen = 24000  // 0.5s tail

var out = Data("SIR1".utf8)
withUnsafeBytes(of: UInt32(sr).littleEndian) { out.append(contentsOf: $0) }
withUnsafeBytes(of: UInt32(irLen).littleEndian) { out.append(contentsOf: $0) }
for (name, h) in [("LL", hLL), ("LR", hLR), ("RL", hRL), ("RR", hRR)] {
    var ir = [Float](repeating: 0, count: irLen)
    let norm = unit * g0
    for i in 0..<irLen { ir[i] = h[w + i] / norm }
    var energy: Float = 0
    vDSP_svesq(ir, 1, &energy, vDSP_Length(irLen))
    var tail: Float = 0
    ir.withUnsafeBufferPointer {
        vDSP_svesq($0.baseAddress! + irLen - irLen / 10, 1, &tail, vDSP_Length(irLen / 10))
    }
    print("\(name): energy \(String(format: "%.4f", energy)), last-10%% tail \(String(format: "%.1f", 10 * log10(tail / energy))) dB of total")
    ir.withUnsafeBytes { out.append(contentsOf: $0) }
}
do {
    try out.write(to: URL(fileURLWithPath: outPath))
} catch {
    die("write \(outPath): \(error)")
}
print("wrote \(outPath): 4 × \(irLen) taps @ \(sr)Hz, direct peak at lag \(Int(peakIdx) - pre) samples")
