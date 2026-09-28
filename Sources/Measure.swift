// Measure.swift: measure Apple's Fixed-mode spatializer in-app. The sweep signal is written
// into a movie (macOS spatializes stereo by default only for content with video) and played
// with AVPlayer in a helper process, like QuickTime in the original measurement. A process
// tap records the helper's output after Apple's in-process render, and the Fixed pass is
// deconvolved (Farina method, regularized spectral division) into the four paths LL, LR, RL,
// RR, normalized so that an unspatialized pass is the unity reference.

import Accelerate
import AVFoundation
import CoreAudio
import Foundation

// Signal @48k: 3s silence (time for the recorder to attach), 3 clicks 0.3s apart (alignment),
// 0.7s, 6s log sweep LEFT only, 1s gap, 6s log sweep RIGHT only, 1s tail.
private let sr = 48000
private let sweepLen = 6 * sr
private let click1 = 3 * sr
private let clickStep = 1 + 14400
private let lSweepStart = click1 + 3 * clickStep + 33600
private let rSweepStart = lSweepStart + sweepLen + sr
private let signalFrames = rSweepStart + sweepLen + sr

private let logSweep: [Float] = {
    let f1 = 40.0, f2 = 18000.0
    let L = 6.0 / log(f2 / f1), K = 2 * Double.pi * f1 * L
    return (0..<sweepLen).map { Float(0.5 * sin(K * (exp(Double($0) / Double(sr) / L) - 1))) }
}()

/// Interleaved stereo.
let measurementSignal: [Float] = {
    var s = [Float](repeating: 0, count: signalFrames * 2)
    for c in 0..<3 {
        s[2 * (click1 + c * clickStep)] = 0.9
        s[2 * (click1 + c * clickStep) + 1] = 0.9
    }
    for i in 0..<sweepLen {
        s[2 * (lSweepStart + i)] = logSweep[i]
        s[2 * (rSweepStart + i) + 1] = logSweep[i]
    }
    return s
}()

/// A tiny black video carrying the signal as 16-bit PCM.
func writeSweepMovie(to url: URL) throws {
    try? FileManager.default.removeItem(at: url)
    let writer = try AVAssetWriter(outputURL: url, fileType: .mov)
    let vIn = AVAssetWriterInput(mediaType: .video, outputSettings: [
        AVVideoCodecKey: AVVideoCodecType.h264, AVVideoWidthKey: 64, AVVideoHeightKey: 64,
    ])
    vIn.expectsMediaDataInRealTime = false
    let adaptor = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: vIn, sourcePixelBufferAttributes: [
        kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
        kCVPixelBufferWidthKey as String: 64,
        kCVPixelBufferHeightKey as String: 64,
    ])
    let aIn = AVAssetWriterInput(mediaType: .audio, outputSettings: [
        AVFormatIDKey: kAudioFormatLinearPCM, AVSampleRateKey: sr, AVNumberOfChannelsKey: 2,
        AVLinearPCMBitDepthKey: 16, AVLinearPCMIsFloatKey: false,
        AVLinearPCMIsBigEndianKey: false, AVLinearPCMIsNonInterleaved: false,
    ])
    writer.add(vIn)
    writer.add(aIn)
    guard writer.startWriting() else { throw writer.error ?? SpatializerError(message: "could not write the test movie") }
    writer.startSession(atSourceTime: .zero)

    // Two black frames pin the video track to the full duration.
    var pb: CVPixelBuffer?
    CVPixelBufferPoolCreatePixelBuffer(nil, adaptor.pixelBufferPool!, &pb)
    guard let pb else { throw SpatializerError(message: "could not create a video frame") }
    CVPixelBufferLockBaseAddress(pb, [])
    memset(CVPixelBufferGetBaseAddress(pb), 0, CVPixelBufferGetBytesPerRow(pb) * 64)
    CVPixelBufferUnlockBaseAddress(pb, [])
    while !vIn.isReadyForMoreMediaData { usleep(10000) }
    adaptor.append(pb, withPresentationTime: .zero)
    while !vIn.isReadyForMoreMediaData { usleep(10000) }
    adaptor.append(pb, withPresentationTime: CMTime(seconds: Double(signalFrames) / Double(sr) - 0.05, preferredTimescale: 600))
    vIn.markAsFinished()

    var asbd = AudioStreamBasicDescription(mSampleRate: Float64(sr), mFormatID: kAudioFormatLinearPCM,
                                           mFormatFlags: kAudioFormatFlagIsFloat | kAudioFormatFlagIsPacked,
                                           mBytesPerPacket: 8, mFramesPerPacket: 1, mBytesPerFrame: 8,
                                           mChannelsPerFrame: 2, mBitsPerChannel: 32, mReserved: 0)
    var layout = AudioChannelLayout()
    layout.mChannelLayoutTag = kAudioChannelLayoutTag_Stereo
    var format: CMAudioFormatDescription?
    try check(CMAudioFormatDescriptionCreate(allocator: nil, asbd: &asbd,
                                             layoutSize: MemoryLayout<AudioChannelLayout>.size, layout: &layout,
                                             magicCookieSize: 0, magicCookie: nil, extensions: nil,
                                             formatDescriptionOut: &format), "create audio format")
    var signal = measurementSignal
    try signal.withUnsafeMutableBufferPointer { buf in
        for offset in stride(from: 0, to: signalFrames, by: sr) {
            let n = min(sr, signalFrames - offset)
            var timing = CMSampleTimingInfo(duration: CMTime(value: 1, timescale: CMTimeScale(sr)),
                                            presentationTimeStamp: CMTime(value: CMTimeValue(offset), timescale: CMTimeScale(sr)),
                                            decodeTimeStamp: .invalid)
            var sbuf: CMSampleBuffer?
            try check(CMSampleBufferCreate(allocator: nil, dataBuffer: nil, dataReady: false,
                                           makeDataReadyCallback: nil, refcon: nil,
                                           formatDescription: format!, sampleCount: n,
                                           sampleTimingEntryCount: 1, sampleTimingArray: &timing,
                                           sampleSizeEntryCount: 0, sampleSizeArray: nil,
                                           sampleBufferOut: &sbuf), "create sample buffer")
            var list = AudioBufferList(mNumberBuffers: 1,
                                       mBuffers: AudioBuffer(mNumberChannels: 2, mDataByteSize: UInt32(n * 8),
                                                             mData: buf.baseAddress! + offset * 2))
            try check(CMSampleBufferSetDataBufferFromAudioBufferList(sbuf!, blockBufferAllocator: nil,
                                                                     blockBufferMemoryAllocator: nil, flags: 0,
                                                                     bufferList: &list), "fill sample buffer")
            while !aIn.isReadyForMoreMediaData { usleep(10000) }
            aIn.append(sbuf!)
        }
    }
    aIn.markAsFinished()
    writer.endSession(atSourceTime: CMTime(value: CMTimeValue(signalFrames), timescale: CMTimeScale(sr)))

    let done = DispatchSemaphore(value: 0)
    writer.finishWriting { done.signal() }
    done.wait()
    guard writer.status == .completed else { throw writer.error ?? SpatializerError(message: "could not write the test movie") }
}

/// Starts this app's executable in sweep-player mode (see `runSweepPlayer`).
func launchSweepPlayer(_ movie: URL, _ flags: [String]) throws -> Process {
    let p = Process()
    p.executableURL = Bundle.main.executableURL
    p.arguments = ["--play-sweep", movie.path] + flags
    try p.run()
    return p
}

/// Entry point of the helper process: plays the movie, forcing spatialization off with
/// `--off`, or quietly on repeat with `--setup`.
func runSweepPlayer(_ args: [String]) -> Never {
    let item = AVPlayerItem(url: URL(fileURLWithPath: args[0]))
    if args.contains("--off") { item.allowedAudioSpatializationFormats = [] }
    let player = AVPlayer(playerItem: item)
    if args.contains("--setup") { player.volume = 0.1 }
    NotificationCenter.default.addObserver(forName: AVPlayerItem.didPlayToEndTimeNotification, object: item, queue: .main) { _ in
        guard args.contains("--setup") else { exit(0) }
        player.seek(to: .zero)
        player.play()
    }
    player.play()
    RunLoop.main.run()
    exit(0)
}

/// Recording time of one pass: the signal plus slack for the helper's start-up and latency.
let passSeconds = Double(signalFrames) / Double(sr) + 1.5

/// Plays the movie once in a helper and returns what the helper output, interleaved stereo.
func recordPass(movie: URL, spatialize: Bool) async throws -> [Float] {
    let helper = try launchSweepPlayer(movie, spatialize ? [] : ["--off"])
    defer { helper.terminate() }
    // The helper appears in the HAL once it starts audio, well inside the signal's lead-in.
    var process = AudioObjectID(kAudioObjectUnknown)
    for _ in 0..<40 {
        process = audioProcess(pid: helper.processIdentifier)
        if process != kAudioObjectUnknown { break }
        try await Task.sleep(for: .milliseconds(50))
    }
    guard process != kAudioObjectUnknown else { throw SpatializerError(message: "The test sound didn't start. Try again.") }
    let recorder = try ProcessRecorder(process, frames: Int(passSeconds * Double(sr)))
    try await Task.sleep(for: .seconds(passSeconds))
    return recorder.finish()
}

func audioProcess(pid: pid_t) -> AudioObjectID {
    var pid = pid
    var process = AudioObjectID(kAudioObjectUnknown)
    var a = addr(kAudioHardwarePropertyTranslatePIDToProcessObject)
    var size = UInt32(MemoryLayout<AudioObjectID>.size)
    AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &a,
                               UInt32(MemoryLayout<pid_t>.size), &pid, &size, &process)
    return process
}

/// Records one process's output through a process tap, muting it so measuring is silent.
final class ProcessRecorder: @unchecked Sendable {
    private var tap = AudioObjectID(kAudioObjectUnknown)
    private var aggregate = AudioObjectID(kAudioObjectUnknown)
    private var procID: AudioDeviceIOProcID?
    private let buffer: UnsafeMutablePointer<Float>
    private let capacity: Int
    private var recorded = 0

    init(_ process: AudioObjectID, frames: Int) throws {
        capacity = frames
        buffer = .allocate(capacity: frames * 2)
        do {
            let desc = CATapDescription(stereoMixdownOfProcesses: [process])
            desc.isPrivate = true
            desc.muteBehavior = .mutedWhenTapped
            try check(AudioHardwareCreateProcessTap(desc, &tap), "create process tap")
            aggregate = try createTapAggregate(tap: desc.uuid).aggregate

            guard let fmt = streamFormat(aggregate, kAudioObjectPropertyScopeInput),
                  fmt.mChannelsPerFrame == 2, fmt.mBitsPerChannel == 32 else {
                throw SpatializerError(message: "tap is not float stereo")
            }
            guard Int(fmt.mSampleRate) == sr else {
                throw SpatializerError(message: "The output runs at \(Int(fmt.mSampleRate)) Hz; measuring needs 48 kHz.")
            }
            try check(AudioDeviceCreateIOProcIDWithBlock(&procID, aggregate, nil) { [unowned self] _, input, _, _, _ in
                let src = UnsafeMutableAudioBufferListPointer(UnsafeMutablePointer(mutating: input))
                guard let data = src.first?.mData else { return }
                let n = min(Int(src[0].mDataByteSize) / 8, capacity - recorded)
                guard n > 0 else { return }
                memcpy(buffer + recorded * 2, data, n * 8)
                recorded += n
            }, "create IOProc")
            try check(AudioDeviceStart(aggregate, procID), "start recording")
        } catch {
            teardown()
            throw error
        }
    }

    deinit {
        teardown()
        buffer.deallocate()
    }

    func finish() -> [Float] {
        teardown()
        return Array(UnsafeBufferPointer(start: buffer, count: recorded * 2))
    }

    private func teardown() {
        if let procID {
            AudioDeviceStop(aggregate, procID)
            AudioDeviceDestroyIOProcID(aggregate, procID)
        }
        if aggregate != kAudioObjectUnknown { AudioHardwareDestroyAggregateDevice(aggregate) }
        if tap != kAudioObjectUnknown { AudioHardwareDestroyProcessTap(tap) }
        procID = nil
        aggregate = AudioObjectID(kAudioObjectUnknown)
        tap = AudioObjectID(kAudioObjectUnknown)
    }
}

// MARK: - deconvolution

private let log2N: vDSP_Length = 20
private let N = 1 << 20

/// Turns a Fixed pass and an unspatialized pass into 'SIR1' IR data (see Spatializer.init).
func extractIR(fixed: [Float], off: [Float]) throws -> Data {
    guard let fft = vDSP_create_fftsetup(log2N, FFTRadix(kFFTRadix2)) else {
        throw SpatializerError(message: "FFT setup failed")
    }
    defer { vDSP_destroy_fftsetup(fft) }

    func forward(_ x: [Float]) -> (re: [Float], im: [Float]) {
        var re = [Float](repeating: 0, count: N / 2), im = re
        let padded = x + [Float](repeating: 0, count: N - x.count)
        re.withUnsafeMutableBufferPointer { rb in
            im.withUnsafeMutableBufferPointer { ib in
                var split = DSPSplitComplex(realp: rb.baseAddress!, imagp: ib.baseAddress!)
                padded.withUnsafeBytes {
                    vDSP_ctoz($0.baseAddress!.assumingMemoryBound(to: DSPComplex.self), 2, &split, 1, vDSP_Length(N / 2))
                }
                vDSP_fft_zrip(fft, &split, 1, log2N, FFTDirection(FFT_FORWARD))
            }
        }
        return (re, im)
    }

    // h = IFFT( Y·X* / (|X|²+λ) ), handling vDSP's packed DC/Nyquist in bin 0.
    func deconvolve(_ y: [Float], _ x: (re: [Float], im: [Float]), _ lambda: Float) -> [Float] {
        let Y = forward(y)
        var re = [Float](repeating: 0, count: N / 2), im = re
        for k in 1..<(N / 2) {
            let xr = x.re[k], xi = x.im[k], yr = Y.re[k], yi = Y.im[k]
            let denom = xr * xr + xi * xi + lambda
            re[k] = (yr * xr + yi * xi) / denom
            im[k] = (yi * xr - yr * xi) / denom
        }
        re[0] = Y.re[0] * x.re[0] / (x.re[0] * x.re[0] + lambda)
        im[0] = Y.im[0] * x.im[0] / (x.im[0] * x.im[0] + lambda)
        var h = [Float](repeating: 0, count: N)
        re.withUnsafeMutableBufferPointer { rb in
            im.withUnsafeMutableBufferPointer { ib in
                var split = DSPSplitComplex(realp: rb.baseAddress!, imagp: ib.baseAddress!)
                vDSP_fft_zrip(fft, &split, 1, log2N, FFTDirection(FFT_INVERSE))
                h.withUnsafeMutableBytes {
                    vDSP_ztoc(&split, 1, $0.baseAddress!.assumingMemoryBound(to: DSPComplex.self), 2, vDSP_Length(N / 2))
                }
            }
        }
        var scale = Float(1) / (2 * Float(N))
        vDSP_vsmul(h, 1, &scale, &h, 1, vDSP_Length(N))
        return h
    }

    let pre = 4800
    let segLen = sweepLen + sr + pre

    func firstClick(_ rec: [Float]) throws -> Int {
        for i in 0..<rec.count / 2 where abs(rec[2 * i]) + abs(rec[2 * i + 1]) > 0.05 { return i }
        throw SpatializerError(message: "No test sound was recorded. Check that Spatialize is allowed to capture audio, then try again.")
    }

    func segment(_ rec: [Float], channel: Int, clickAt: Int, sourceStart: Int) throws -> [Float] {
        let start = clickAt + sourceStart - click1 - pre
        guard start >= 0, 2 * (start + segLen) <= rec.count else {
            throw SpatializerError(message: "The recording was cut short. Try again.")
        }
        return (start..<(start + segLen)).map { rec[2 * $0 + channel] }
    }

    func peak(_ h: [Float]) -> Int {
        var value: Float = 0
        var index: vDSP_Length = 0
        vDSP_maxmgvi(h, 1, &value, &index, vDSP_Length(pre + 2 * sr))
        return Int(index)
    }

    let X = forward(logSweep)
    var mx: Float = 0
    vDSP_maxmgv(X.re, 1, &mx, vDSP_Length(N / 2))
    let lambda = (1e-4 * mx) * (1e-4 * mx)
    // Self-calibrate the FFT scale: the sweep deconvolved against itself must be a unit impulse.
    let unit = deconvolve(logSweep, X, lambda)[0]

    let offH = deconvolve(try segment(off, channel: 0, clickAt: firstClick(off), sourceStart: lSweepStart), X, lambda)
    let g0 = offH[peak(offH)] / unit

    let fixedClick = try firstClick(fixed)
    let paths = try [(0, lSweepStart), (1, lSweepStart), (0, rSweepStart), (1, rSweepStart)].map {  // LL LR RL RR
        deconvolve(try segment(fixed, channel: $0.0, clickAt: fixedClick, sourceStart: $0.1), X, lambda)
    }

    // One shared window keeps inter-path timing intact: anchor on the LL direct peak.
    let w = max(peak(paths[0]) - 256, 0)
    let irLen = 24000  // 0.5s tail
    let irs = paths.map { h in (0..<irLen).map { h[w + $0] / (unit * g0) } }

    // Unspatialized stereo has no L→R path at all; any binaural render has plenty.
    let energy = irs.map { $0.reduce(0) { $0 + $1 * $1 } }
    guard energy[1] > 0.01 * energy[0] else {
        throw SpatializerError(message: "The test sound wasn't spatialized. Check that your AirPods are the output and Spatialize Stereo is set to Fixed, then try again.")
    }

    var out = Data("SIR1".utf8)
    withUnsafeBytes(of: UInt32(sr).littleEndian) { out.append(contentsOf: $0) }
    withUnsafeBytes(of: UInt32(irLen).littleEndian) { out.append(contentsOf: $0) }
    for ir in irs { ir.withUnsafeBytes { out.append(contentsOf: $0) } }
    return out
}
