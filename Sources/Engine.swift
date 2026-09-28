// Engine.swift — real-time spatializer: process tap + partitioned FFT convolution with
// impulse responses measured from Apple's own Fixed-mode spatializer (see Measure.swift).

import Accelerate
import AudioToolbox
import CoreAudio
import Foundation

struct SpatializerError: LocalizedError {
    let message: String
    var errorDescription: String? { message }
}

func check(_ status: OSStatus, _ what: String) throws {
    if status != noErr { throw SpatializerError(message: "\(what) (OSStatus \(status))") }
}

func addr(_ sel: AudioObjectPropertySelector,
                  _ scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal) -> AudioObjectPropertyAddress {
    AudioObjectPropertyAddress(mSelector: sel, mScope: scope, mElement: kAudioObjectPropertyElementMain)
}

private func objectIDs(_ obj: AudioObjectID, _ sel: AudioObjectPropertySelector,
                       _ scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal) -> [AudioObjectID] {
    var a = addr(sel, scope), size: UInt32 = 0
    guard AudioObjectGetPropertyDataSize(obj, &a, 0, nil, &size) == noErr, size > 0 else { return [] }
    var ids = [AudioObjectID](repeating: 0, count: Int(size) / MemoryLayout<AudioObjectID>.size)
    guard AudioObjectGetPropertyData(obj, &a, 0, nil, &size, &ids) == noErr else { return [] }
    return ids
}

private func stringProp(_ obj: AudioObjectID, _ sel: AudioObjectPropertySelector) -> String? {
    var a = addr(sel), size = UInt32(MemoryLayout<CFString?>.size)
    var value: Unmanaged<CFString>?
    let status = withUnsafeMutablePointer(to: &value) {
        AudioObjectGetPropertyData(obj, &a, 0, nil, &size, $0)
    }
    guard status == noErr else { return nil }
    return value?.takeRetainedValue() as String?
}

private func uint32Prop(_ obj: AudioObjectID, _ sel: AudioObjectPropertySelector) -> UInt32? {
    var a = addr(sel), size = UInt32(MemoryLayout<UInt32>.size), value: UInt32 = 0
    return AudioObjectGetPropertyData(obj, &a, 0, nil, &size, &value) == noErr ? value : nil
}

/// A Bluetooth mic as default input drops the headset into its mono, low-rate call profile
/// (HFP). Moves the default input to the built-in mic; returns whether it did.
@discardableResult
func moveDefaultInputOffBluetooth() -> Bool {
    let system = AudioObjectID(kAudioObjectSystemObject)
    let bluetooth = [kAudioDeviceTransportTypeBluetooth, kAudioDeviceTransportTypeBluetoothLE]
    guard let input = uint32Prop(system, kAudioHardwarePropertyDefaultInputDevice),
          let transport = uint32Prop(input, kAudioDevicePropertyTransportType),
          bluetooth.contains(transport),
          var builtIn = objectIDs(system, kAudioHardwarePropertyDevices).first(where: {
              uint32Prop($0, kAudioDevicePropertyTransportType) == kAudioDeviceTransportTypeBuiltIn
                  && !objectIDs($0, kAudioDevicePropertyStreams, kAudioObjectPropertyScopeInput).isEmpty
          }) else { return false }
    var a = addr(kAudioHardwarePropertyDefaultInputDevice)
    return AudioObjectSetPropertyData(system, &a, 0, nil, UInt32(MemoryLayout<AudioObjectID>.size), &builtIn) == noErr
}

/// Private aggregate on the default output device with the tap as its input.
func createTapAggregate(tap: UUID) throws -> (aggregate: AudioObjectID, output: AudioObjectID) {
    guard let output = uint32Prop(AudioObjectID(kAudioObjectSystemObject), kAudioHardwarePropertyDefaultOutputDevice),
          let outUID = stringProp(output, kAudioDevicePropertyDeviceUID) else {
        throw SpatializerError(message: "no output device")
    }
    let desc: [String: Any] = [
        kAudioAggregateDeviceNameKey: "Spatialize",
        kAudioAggregateDeviceUIDKey: UUID().uuidString,
        kAudioAggregateDeviceMainSubDeviceKey: outUID,
        kAudioAggregateDeviceIsPrivateKey: true,
        kAudioAggregateDeviceIsStackedKey: false,
        kAudioAggregateDeviceTapAutoStartKey: true,
        kAudioAggregateDeviceSubDeviceListKey: [[kAudioSubDeviceUIDKey: outUID]],
        kAudioAggregateDeviceTapListKey: [[
            kAudioSubTapDriftCompensationKey: true,
            kAudioSubTapUIDKey: tap.uuidString,
        ]],
    ]
    var aggregate = AudioObjectID(kAudioObjectUnknown)
    try check(AudioHardwareCreateAggregateDevice(desc as CFDictionary, &aggregate), "create aggregate device")
    return (aggregate, output)
}

func streamFormat(_ dev: AudioObjectID, _ scope: AudioObjectPropertyScope) -> AudioStreamBasicDescription? {
    guard let stream = objectIDs(dev, kAudioDevicePropertyStreams, scope).first else { return nil }
    var a = addr(kAudioStreamPropertyVirtualFormat)
    var fmt = AudioStreamBasicDescription()
    var size = UInt32(MemoryLayout<AudioStreamBasicDescription>.size)
    guard AudioObjectGetPropertyData(stream, &a, 0, nil, &size, &fmt) == noErr else { return nil }
    return fmt
}

private func alloc(_ n: Int) -> UnsafeMutablePointer<Float> {
    let p = UnsafeMutablePointer<Float>.allocate(capacity: n)
    p.initialize(repeating: 0, count: n)
    return p
}

// The HAL IOProc must be a context-free C function; the engine instance travels via refcon.
private let ioProc: AudioDeviceIOProc = { _, _, inputData, _, outputData, _, refcon in
    Unmanaged<Spatializer>.fromOpaque(refcon!).takeUnretainedValue().render(inputData, outputData)
}

final class Spatializer {
    static let block = 512
    private let B = Spatializer.block
    private let F = 1024
    private let halfF = 512
    private let log2F: vDSP_Length = 10

    let irRate: Int
    let irLen: Int
    private let P: Int
    private let fft: FFTSetup
    private var calNorm: Float = 1
    private var hRe: [UnsafeMutablePointer<Float>] = []  // 4 paths: LL, LR, RL, RR
    private var hIm: [UnsafeMutablePointer<Float>] = []

    // Runtime DSP state
    private let fftScratch: UnsafeMutablePointer<Float>
    private let prevL: UnsafeMutablePointer<Float>
    private let prevR: UnsafeMutablePointer<Float>
    private let curL: UnsafeMutablePointer<Float>
    private let curR: UnsafeMutablePointer<Float>
    private let xRe: [UnsafeMutablePointer<Float>]
    private let xIm: [UnsafeMutablePointer<Float>]
    private let accRe: [UnsafeMutablePointer<Float>]
    private let accIm: [UnsafeMutablePointer<Float>]
    private let outBlockL: UnsafeMutablePointer<Float>
    private let outBlockR: UnsafeMutablePointer<Float>
    private var head = 0

    private let fifoSize = 1 << 14
    private let fifoMask = (1 << 14) - 1
    private let inL: UnsafeMutablePointer<Float>
    private let inR: UnsafeMutablePointer<Float>
    private let outL: UnsafeMutablePointer<Float>
    private let outR: UnsafeMutablePointer<Float>
    private var inW = 0
    private var inRd = 0
    private var outW = 0
    private var outRd = 0

    // Graph
    private var tapID = AudioObjectID(kAudioObjectUnknown)
    private var aggregate = AudioObjectID(kAudioObjectUnknown)
    private var procID: AudioDeviceIOProcID?
    private(set) var tappedProcesses: [AudioObjectID] = []
    private(set) var deviceName = ""
    var isRunning: Bool { procID != nil }

    static func audioProcesses(bundleIDs: [String]) -> [AudioObjectID] {
        objectIDs(AudioObjectID(kAudioObjectSystemObject), kAudioHardwarePropertyProcessObjectList)
            .filter { bundleIDs.contains(stringProp($0, kAudioProcessPropertyBundleID) ?? "") }
    }

    /// Bundle IDs of every app currently registered with the audio HAL.
    static func runningAudioBundleIDs() -> [String] {
        var seen = Set<String>()
        for p in objectIDs(AudioObjectID(kAudioObjectSystemObject), kAudioHardwarePropertyProcessObjectList) {
            if let b = stringProp(p, kAudioProcessPropertyBundleID), !b.isEmpty { seen.insert(b) }
        }
        return Array(seen)
    }

    init(irData: Data) throws {
        guard irData.count > 12, irData.prefix(4) == Data("SIR1".utf8) else {
            throw SpatializerError(message: "bad IR file (expected SIR1 magic)")
        }
        irRate = Int(irData.withUnsafeBytes { $0.loadUnaligned(fromByteOffset: 4, as: UInt32.self) })
        irLen = Int(irData.withUnsafeBytes { $0.loadUnaligned(fromByteOffset: 8, as: UInt32.self) })
        guard irData.count == 12 + 4 * irLen * 4 else { throw SpatializerError(message: "truncated IR file") }
        P = (irLen + B - 1) / B
        guard let setup = vDSP_create_fftsetup(log2F, FFTRadix(kFFTRadix2)) else {
            throw SpatializerError(message: "FFT setup failed")
        }
        fft = setup

        fftScratch = alloc(F)
        prevL = alloc(B); prevR = alloc(B)
        curL = alloc(B); curR = alloc(B)
        xRe = [alloc(P * halfF), alloc(P * halfF)]
        xIm = [alloc(P * halfF), alloc(P * halfF)]
        accRe = [alloc(halfF), alloc(halfF)]
        accIm = [alloc(halfF), alloc(halfF)]
        outBlockL = alloc(B); outBlockR = alloc(B)
        inL = alloc(fifoSize); inR = alloc(fifoSize)
        outL = alloc(fifoSize); outR = alloc(fifoSize)

        // Partition spectra: IR block in the FIRST half of the frame ([h | 0]), unlike
        // input frames ([prev | cur]) — that offset makes the last-B window valid.
        let zero = alloc(B)
        let padded = alloc(B)
        defer { zero.deallocate(); padded.deallocate() }
        for path in 0..<4 {
            let re = alloc(P * halfF), im = alloc(P * halfF)
            for p in 0..<P {
                let n = min(B, irLen - p * B)
                irData.withUnsafeBytes { raw in
                    let base = raw.baseAddress!.advanced(by: 12 + path * irLen * 4 + p * B * 4)
                    memcpy(padded, base, n * 4)
                }
                if n < B { memset(padded + n, 0, (B - n) * 4) }
                fwd(padded, zero, re + p * halfF, im + p * halfF)
            }
            hRe.append(re)
            hIm.append(im)
        }

        // Calibrate the vDSP scale convention with the normal block pipeline: δ input
        // through a δ IR must give back δ; the deviation becomes `calNorm` (1 so far,
        // so `inv` below is unscaled).
        memset(padded, 0, B * 4)
        padded[0] = 1
        let dRe = alloc(halfF), dIm = alloc(halfF)
        let xr = alloc(halfF), xi = alloc(halfF)
        defer { [dRe, dIm, xr, xi].forEach { $0.deallocate() } }
        fwd(padded, zero, dRe, dIm)  // δ "IR" partition: [h | 0]
        fwd(zero, padded, xr, xi)    // δ input frame: [prev | cur]
        memset(accRe[0], 0, halfF * 4)
        memset(accIm[0], 0, halfF * 4)
        mac(xr, xi, dRe, dIm, accRe[0], accIm[0])
        inv(accRe[0], accIm[0], outBlockL)
        guard outBlockL[0] != 0 else { throw SpatializerError(message: "engine calibration failed") }
        calNorm = 1 / outBlockL[0]
    }

    private func fwd(_ first: UnsafePointer<Float>, _ second: UnsafePointer<Float>,
                     _ re: UnsafeMutablePointer<Float>, _ im: UnsafeMutablePointer<Float>) {
        memcpy(fftScratch, first, B * 4)
        memcpy(fftScratch + B, second, B * 4)
        var split = DSPSplitComplex(realp: re, imagp: im)
        fftScratch.withMemoryRebound(to: DSPComplex.self, capacity: halfF) {
            vDSP_ctoz($0, 2, &split, 1, vDSP_Length(halfF))
        }
        vDSP_fft_zrip(fft, &split, 1, log2F, FFTDirection(FFT_FORWARD))
    }

    // acc += x · h (packed spectra: bin 0 holds DC in re and Nyquist in im, both real)
    @inline(__always)
    private func mac(_ xr: UnsafePointer<Float>, _ xi: UnsafePointer<Float>,
                     _ hr: UnsafePointer<Float>, _ hi: UnsafePointer<Float>,
                     _ ar: UnsafeMutablePointer<Float>, _ ai: UnsafeMutablePointer<Float>) {
        ar[0] += xr[0] * hr[0]
        ai[0] += xi[0] * hi[0]
        for k in 1..<halfF {
            let a = xr[k], b = xi[k], c = hr[k], d = hi[k]
            ar[k] += a * c - b * d
            ai[k] += a * d + b * c
        }
    }

    private func inv(_ re: UnsafeMutablePointer<Float>, _ im: UnsafeMutablePointer<Float>,
                     _ out: UnsafeMutablePointer<Float>) {
        var split = DSPSplitComplex(realp: re, imagp: im)
        vDSP_fft_zrip(fft, &split, 1, log2F, FFTDirection(FFT_INVERSE))
        fftScratch.withMemoryRebound(to: DSPComplex.self, capacity: halfF) {
            vDSP_ztoc(&split, 1, $0, 2, vDSP_Length(halfF))
        }
        var scale = calNorm
        vDSP_vsmul(fftScratch + B, 1, &scale, out, 1, vDSP_Length(B))
    }

    private func processBlock() {
        for i in 0..<B {
            curL[i] = inL[(inRd + i) & fifoMask]
            curR[i] = inR[(inRd + i) & fifoMask]
        }
        inRd += B

        fwd(prevL, curL, xRe[0] + head * halfF, xIm[0] + head * halfF)
        fwd(prevR, curR, xRe[1] + head * halfF, xIm[1] + head * halfF)
        memcpy(prevL, curL, B * 4)
        memcpy(prevR, curR, B * 4)

        for c in 0..<2 {
            memset(accRe[c], 0, halfF * 4)
            memset(accIm[c], 0, halfF * 4)
        }
        for p in 0..<P {
            let idx = ((head - p) % P + P) % P
            mac(xRe[0] + idx * halfF, xIm[0] + idx * halfF, hRe[0] + p * halfF, hIm[0] + p * halfF, accRe[0], accIm[0])
            mac(xRe[1] + idx * halfF, xIm[1] + idx * halfF, hRe[2] + p * halfF, hIm[2] + p * halfF, accRe[0], accIm[0])
            mac(xRe[0] + idx * halfF, xIm[0] + idx * halfF, hRe[1] + p * halfF, hIm[1] + p * halfF, accRe[1], accIm[1])
            mac(xRe[1] + idx * halfF, xIm[1] + idx * halfF, hRe[3] + p * halfF, hIm[3] + p * halfF, accRe[1], accIm[1])
        }
        head = (head + 1) % P

        inv(accRe[0], accIm[0], outBlockL)
        inv(accRe[1], accIm[1], outBlockR)
        for i in 0..<B {
            outL[(outW + i) & fifoMask] = outBlockL[i]
            outR[(outW + i) & fifoMask] = outBlockR[i]
        }
        outW += B
    }

    fileprivate func render(_ inputData: UnsafePointer<AudioBufferList>,
                            _ outputData: UnsafeMutablePointer<AudioBufferList>) -> OSStatus {
        let src = UnsafeMutableAudioBufferListPointer(UnsafeMutablePointer(mutating: inputData))
        let dst = outputData.pointee.mBuffers
        let outFrames = Int(dst.mDataByteSize) / 8
        guard let deviceBuffer = dst.mData?.assumingMemoryBound(to: Float.self), dst.mNumberChannels == 2 else { return noErr }

        if src.count >= 1, src[0].mNumberChannels == 2,
           let data = src[0].mData?.assumingMemoryBound(to: Float.self) {
            let n = Int(src[0].mDataByteSize) / 8
            for i in 0..<n {
                inL[(inW + i) & fifoMask] = data[2 * i]
                inR[(inW + i) & fifoMask] = data[2 * i + 1]
            }
            inW += n
        }

        while inW - inRd >= B { processBlock() }
        for i in 0..<outFrames {
            let has = outRd < outW
            deviceBuffer[2 * i] = has ? outL[outRd & fifoMask] : 0
            deviceBuffer[2 * i + 1] = has ? outR[outRd & fifoMask] : 0
            if has { outRd += 1 }
        }
        return noErr
    }

    func start(bundleIDs: [String]) throws {
        stop()
        do {
            let processes = Self.audioProcesses(bundleIDs: bundleIDs)
            guard !processes.isEmpty else {
                throw SpatializerError(message: "no target app is playing audio yet")
            }

            let tapDesc = CATapDescription(stereoMixdownOfProcesses: processes)
            tapDesc.name = "Spatialize"
            tapDesc.isPrivate = true
            tapDesc.muteBehavior = .mutedWhenTapped
            var tap = AudioObjectID(kAudioObjectUnknown)
            try check(AudioHardwareCreateProcessTap(tapDesc, &tap), "create process tap")
            tapID = tap

            let (agg, defaultOut) = try createTapAggregate(tap: tapDesc.uuid)
            aggregate = agg

            var frames = UInt32(B)
            var sizeAddr = addr(kAudioDevicePropertyBufferFrameSize)
            AudioObjectSetPropertyData(aggregate, &sizeAddr, 0, nil, UInt32(MemoryLayout<UInt32>.size), &frames)

            guard let inFormat = streamFormat(aggregate, kAudioObjectPropertyScopeInput),
                  let outFormat = streamFormat(aggregate, kAudioObjectPropertyScopeOutput) else {
                throw SpatializerError(message: "aggregate device has no streams")
            }
            guard inFormat.mSampleRate == outFormat.mSampleRate else {
                throw SpatializerError(message: "tap and output sample rates differ")
            }
            guard Int(outFormat.mSampleRate) == irRate else {
                throw SpatializerError(message: "IRs are \(irRate)Hz but device runs \(Int(outFormat.mSampleRate))Hz")
            }
            guard outFormat.mChannelsPerFrame == 2, outFormat.mBitsPerChannel == 32 else {
                throw SpatializerError(message: "output device is not float stereo")
            }

            // Reset DSP state for a clean start
            memset(prevL, 0, B * 4); memset(prevR, 0, B * 4)
            for c in 0..<2 {
                memset(xRe[c], 0, P * halfF * 4)
                memset(xIm[c], 0, P * halfF * 4)
            }
            memset(outL, 0, fifoSize * 4); memset(outR, 0, fifoSize * 4)
            head = 0
            inW = 0; inRd = 0
            outW = B; outRd = 0  // one block of pre-roll silence

            var pid: AudioDeviceIOProcID?
            try check(AudioDeviceCreateIOProcID(aggregate, ioProc, Unmanaged.passUnretained(self).toOpaque(), &pid),
                      "create IOProc")
            procID = pid
            try check(AudioDeviceStart(aggregate, pid), "start device")

            tappedProcesses = processes
            deviceName = stringProp(defaultOut, kAudioObjectPropertyName) ?? "output device"
        } catch {
            stop()
            throw error
        }
    }

    func stop() {
        if aggregate != kAudioObjectUnknown {
            if let procID {
                AudioDeviceStop(aggregate, procID)
                AudioDeviceDestroyIOProcID(aggregate, procID)
            }
            AudioHardwareDestroyAggregateDevice(aggregate)
        }
        if tapID != kAudioObjectUnknown {
            AudioHardwareDestroyProcessTap(tapID)
        }
        aggregate = AudioObjectID(kAudioObjectUnknown)
        tapID = AudioObjectID(kAudioObjectUnknown)
        procID = nil
        tappedProcesses = []
        deviceName = ""
    }
}
