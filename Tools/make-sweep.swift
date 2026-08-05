// make-sweep.swift — build sweep.mov: a tiny black video carrying a measurement signal.
// Video container matters: macOS spatializes stereo BY DEFAULT only for assets with video.
//
//   swiftc -O make-sweep.swift -o make-sweep && ./make-sweep
//
// Signal @48k, ±channels measured separately so the full 2-in/2-out response can be
// recovered: 1s silence, 3 clicks (alignment), 6s log sweep LEFT only, 1s gap,
// 6s log sweep RIGHT only, 1s tail.

import AVFoundation
import Foundation

let sr = 48000
var samples = [Float]()  // interleaved L R

func silence(_ seconds: Double) {
    samples.append(contentsOf: [Float](repeating: 0, count: Int(seconds * Double(sr)) * 2))
}
func click() {
    samples.append(0.9)
    samples.append(0.9)
    silence(0.3)
}
func sweep(_ seconds: Double, left: Bool) {
    let n = Int(seconds * Double(sr))
    let f1 = 40.0, f2 = 18000.0
    let L = seconds / log(f2 / f1)
    let K = 2 * Double.pi * f1 * L
    for i in 0..<n {
        let t = Double(i) / Double(sr)
        let v = Float(0.5 * sin(K * (exp(t / L) - 1)))
        samples.append(left ? v : 0)
        samples.append(left ? 0 : v)
    }
}

silence(1)
click(); click(); click()
silence(0.7)
sweep(6, left: true)
silence(1)
sweep(6, left: false)
silence(1)

let frames = samples.count / 2
let duration = Double(frames) / Double(sr)

let url = URL(fileURLWithPath: "sweep.mov")
try? FileManager.default.removeItem(at: url)
let writer = try! AVAssetWriter(outputURL: url, fileType: .mov)

let vIn = AVAssetWriterInput(mediaType: .video, outputSettings: [
    AVVideoCodecKey: AVVideoCodecType.h264,
    AVVideoWidthKey: 64,
    AVVideoHeightKey: 64,
])
vIn.expectsMediaDataInRealTime = false
let adaptor = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: vIn, sourcePixelBufferAttributes: [
    kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
    kCVPixelBufferWidthKey as String: 64,
    kCVPixelBufferHeightKey as String: 64,
])

let aIn = AVAssetWriterInput(mediaType: .audio, outputSettings: [
    AVFormatIDKey: kAudioFormatLinearPCM,
    AVSampleRateKey: sr,
    AVNumberOfChannelsKey: 2,
    AVLinearPCMBitDepthKey: 16,
    AVLinearPCMIsFloatKey: false,
    AVLinearPCMIsBigEndianKey: false,
    AVLinearPCMIsNonInterleaved: false,
])

writer.add(vIn)
writer.add(aIn)
guard writer.startWriting() else { fatalError("startWriting: \(writer.error.map(String.init(describing:)) ?? "?")") }
writer.startSession(atSourceTime: .zero)

// Two black frames pin the video track to the full duration.
var pbOpt: CVPixelBuffer?
CVPixelBufferPoolCreatePixelBuffer(nil, adaptor.pixelBufferPool!, &pbOpt)
let pb = pbOpt!
CVPixelBufferLockBaseAddress(pb, [])
memset(CVPixelBufferGetBaseAddress(pb), 0, CVPixelBufferGetBytesPerRow(pb) * 64)
CVPixelBufferUnlockBaseAddress(pb, [])
while !vIn.isReadyForMoreMediaData { usleep(10000) }
adaptor.append(pb, withPresentationTime: .zero)
while !vIn.isReadyForMoreMediaData { usleep(10000) }
adaptor.append(pb, withPresentationTime: CMTime(seconds: duration - 0.05, preferredTimescale: 600))
vIn.markAsFinished()

var asbd = AudioStreamBasicDescription(mSampleRate: Float64(sr), mFormatID: kAudioFormatLinearPCM,
                                       mFormatFlags: kAudioFormatFlagIsFloat | kAudioFormatFlagIsPacked,
                                       mBytesPerPacket: 8, mFramesPerPacket: 1, mBytesPerFrame: 8,
                                       mChannelsPerFrame: 2, mBitsPerChannel: 32, mReserved: 0)
var layout = AudioChannelLayout()
layout.mChannelLayoutTag = kAudioChannelLayoutTag_Stereo
var fmtDescOpt: CMAudioFormatDescription?
withUnsafePointer(to: &layout) {
    _ = CMAudioFormatDescriptionCreate(allocator: nil, asbd: &asbd,
                                       layoutSize: MemoryLayout<AudioChannelLayout>.size, layout: $0,
                                       magicCookieSize: 0, magicCookie: nil, extensions: nil,
                                       formatDescriptionOut: &fmtDescOpt)
}
let fmtDesc = fmtDescOpt!

let chunkFrames = 48000
var offset = 0
samples.withUnsafeMutableBufferPointer { buf in
    while offset < frames {
        let n = min(chunkFrames, frames - offset)
        var timing = CMSampleTimingInfo(duration: CMTime(value: 1, timescale: CMTimeScale(sr)),
                                        presentationTimeStamp: CMTime(value: CMTimeValue(offset), timescale: CMTimeScale(sr)),
                                        decodeTimeStamp: .invalid)
        var sbufOpt: CMSampleBuffer?
        guard CMSampleBufferCreate(allocator: kCFAllocatorDefault, dataBuffer: nil, dataReady: false,
                                   makeDataReadyCallback: nil, refcon: nil,
                                   formatDescription: fmtDesc, sampleCount: n,
                                   sampleTimingEntryCount: 1, sampleTimingArray: &timing,
                                   sampleSizeEntryCount: 0, sampleSizeArray: nil,
                                   sampleBufferOut: &sbufOpt) == noErr, let sbuf = sbufOpt else {
            fatalError("CMSampleBufferCreate failed")
        }
        var abl = AudioBufferList(mNumberBuffers: 1,
                                  mBuffers: AudioBuffer(mNumberChannels: 2,
                                                        mDataByteSize: UInt32(n * 8),
                                                        mData: UnsafeMutableRawPointer(buf.baseAddress! + offset * 2)))
        guard CMSampleBufferSetDataBufferFromAudioBufferList(sbuf,
                blockBufferAllocator: kCFAllocatorDefault,
                blockBufferMemoryAllocator: kCFAllocatorDefault,
                flags: 0, bufferList: &abl) == noErr else {
            fatalError("SetDataBufferFromAudioBufferList failed")
        }
        while !aIn.isReadyForMoreMediaData { usleep(10000) }
        aIn.append(sbuf)
        offset += n
    }
}
aIn.markAsFinished()

let sem = DispatchSemaphore(value: 0)
writer.finishWriting { sem.signal() }
sem.wait()
if writer.status != .completed {
    fatalError("finishWriting: \(writer.error.map(String.init(describing:)) ?? "?")")
}
print("wrote sweep.mov: \(String(format: "%.1f", duration))s, clicks + L sweep + R sweep")
