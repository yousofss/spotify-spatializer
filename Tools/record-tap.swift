// record-tap.swift — record an app's audio (after its in-process effects, e.g. Apple's
// spatializer) to a float32 WAV.
//
//   swiftc -O record-tap.swift -o record-tap
//   ./record-tap <bundle.id> <out.wav> [seconds]
//
// The tap is NOT muted: you keep hearing the app while recording.

import AudioToolbox
import CoreAudio
import Darwin
import Foundation

let args = CommandLine.arguments
guard args.count >= 3 else {
    FileHandle.standardError.write(Data("usage: record-tap <bundle.id> <out.wav> [seconds]\n".utf8))
    exit(2)
}
let bundleID = args[1]
let outPath = args[2]
let seconds = args.count > 3 ? (Double(args[3]) ?? 20) : 20

func die(_ msg: String) -> Never {
    FileHandle.standardError.write(Data("error: \(msg)\n".utf8))
    exit(1)
}

func check(_ status: OSStatus, _ what: String) {
    if status != noErr { die("\(what) (OSStatus \(status))") }
}

func addr(_ sel: AudioObjectPropertySelector,
          _ scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal) -> AudioObjectPropertyAddress {
    AudioObjectPropertyAddress(mSelector: sel, mScope: scope, mElement: kAudioObjectPropertyElementMain)
}

func objectIDs(_ obj: AudioObjectID, _ sel: AudioObjectPropertySelector,
               _ scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal) -> [AudioObjectID] {
    var a = addr(sel, scope), size: UInt32 = 0
    guard AudioObjectGetPropertyDataSize(obj, &a, 0, nil, &size) == noErr, size > 0 else { return [] }
    var ids = [AudioObjectID](repeating: 0, count: Int(size) / MemoryLayout<AudioObjectID>.size)
    guard AudioObjectGetPropertyData(obj, &a, 0, nil, &size, &ids) == noErr else { return [] }
    return ids
}

func stringProp(_ obj: AudioObjectID, _ sel: AudioObjectPropertySelector) -> String? {
    var a = addr(sel), size = UInt32(MemoryLayout<CFString?>.size)
    var value: Unmanaged<CFString>?
    let status = withUnsafeMutablePointer(to: &value) {
        AudioObjectGetPropertyData(obj, &a, 0, nil, &size, $0)
    }
    guard status == noErr else { return nil }
    return value?.takeRetainedValue() as String?
}

func streamFormat(_ dev: AudioObjectID, _ scope: AudioObjectPropertyScope) -> AudioStreamBasicDescription? {
    guard let stream = objectIDs(dev, kAudioDevicePropertyStreams, scope).first else { return nil }
    var a = addr(kAudioStreamPropertyVirtualFormat)
    var fmt = AudioStreamBasicDescription()
    var size = UInt32(MemoryLayout<AudioStreamBasicDescription>.size)
    guard AudioObjectGetPropertyData(stream, &a, 0, nil, &size, &fmt) == noErr else { return nil }
    return fmt
}

let system = AudioObjectID(kAudioObjectSystemObject)
let processes = objectIDs(system, kAudioHardwarePropertyProcessObjectList)
    .filter { stringProp($0, kAudioProcessPropertyBundleID) == bundleID }
if processes.isEmpty {
    die("no audio process for \(bundleID) — start playback in it once, then retry")
}

let tapDesc = CATapDescription(stereoMixdownOfProcesses: processes)
tapDesc.name = "Recorder"
tapDesc.isPrivate = true

var tapID = AudioObjectID(kAudioObjectUnknown)
check(AudioHardwareCreateProcessTap(tapDesc, &tapID), "create process tap")

var defaultOut = AudioObjectID(kAudioObjectUnknown)
var outAddr = addr(kAudioHardwarePropertyDefaultOutputDevice)
var outSize = UInt32(MemoryLayout<AudioObjectID>.size)
check(AudioObjectGetPropertyData(system, &outAddr, 0, nil, &outSize, &defaultOut), "get default output device")
guard let outUID = stringProp(defaultOut, kAudioDevicePropertyDeviceUID) else { die("output device has no UID") }

let aggDescription: [String: Any] = [
    kAudioAggregateDeviceNameKey: "Recorder",
    kAudioAggregateDeviceUIDKey: UUID().uuidString,
    kAudioAggregateDeviceMainSubDeviceKey: outUID,
    kAudioAggregateDeviceIsPrivateKey: true,
    kAudioAggregateDeviceIsStackedKey: false,
    kAudioAggregateDeviceTapAutoStartKey: true,
    kAudioAggregateDeviceSubDeviceListKey: [[kAudioSubDeviceUIDKey: outUID]],
    kAudioAggregateDeviceTapListKey: [[
        kAudioSubTapDriftCompensationKey: true,
        kAudioSubTapUIDKey: tapDesc.uuid.uuidString,
    ]],
]

var aggregate = AudioObjectID(kAudioObjectUnknown)
check(AudioHardwareCreateAggregateDevice(aggDescription as CFDictionary, &aggregate), "create aggregate device")

guard let inFormat = streamFormat(aggregate, kAudioObjectPropertyScopeInput),
      inFormat.mChannelsPerFrame == 2, inFormat.mBitsPerChannel == 32 else {
    die("tap is not 32-bit float stereo")
}
let rate = Int(inFormat.mSampleRate)

let capacity = Int(seconds * Double(rate))
nonisolated(unsafe) let buffer = UnsafeMutablePointer<Float>.allocate(capacity: capacity * 2)
nonisolated(unsafe) var recorded = 0

let ioProc: AudioDeviceIOProc = { _, _, inputData, _, _, _, _ in
    let src = UnsafeMutableAudioBufferListPointer(UnsafeMutablePointer(mutating: inputData))
    guard src.count >= 1, src[0].mNumberChannels == 2,
          let data = src[0].mData?.assumingMemoryBound(to: Float.self) else { return noErr }
    let n = min(Int(src[0].mDataByteSize) / 8, capacity - recorded)
    guard n > 0 else { return noErr }
    memcpy(buffer + recorded * 2, data, n * 8)
    recorded += n
    return noErr
}

var procID: AudioDeviceIOProcID?
check(AudioDeviceCreateIOProcID(aggregate, ioProc, nil, &procID), "create IOProc")
check(AudioDeviceStart(aggregate, procID), "start device")

print("recording \(bundleID) for \(Int(seconds))s @ \(rate)Hz → \(outPath) — press play now")

DispatchQueue.main.asyncAfter(deadline: .now() + seconds + 1) {
    AudioDeviceStop(aggregate, procID)
    if let procID { AudioDeviceDestroyIOProcID(aggregate, procID) }
    AudioHardwareDestroyAggregateDevice(aggregate)
    AudioHardwareDestroyProcessTap(tapID)

    var peak: Float = 0
    for i in 0..<(recorded * 2) where abs(buffer[i]) > peak { peak = abs(buffer[i]) }

    var d = Data()
    func le32(_ v: UInt32) { withUnsafeBytes(of: v.littleEndian) { d.append(contentsOf: $0) } }
    func le16(_ v: UInt16) { withUnsafeBytes(of: v.littleEndian) { d.append(contentsOf: $0) } }
    let byteCount = recorded * 8
    d.append(contentsOf: "RIFF".utf8); le32(UInt32(36 + byteCount)); d.append(contentsOf: "WAVE".utf8)
    d.append(contentsOf: "fmt ".utf8); le32(16); le16(3); le16(2)  // format 3 = IEEE float
    le32(UInt32(rate)); le32(UInt32(rate * 8)); le16(8); le16(32)
    d.append(contentsOf: "data".utf8); le32(UInt32(byteCount))
    d.append(Data(bytes: buffer, count: byteCount))
    do {
        try d.write(to: URL(fileURLWithPath: outPath))
    } catch {
        die("write \(outPath): \(error)")
    }
    print("wrote \(outPath): \(recorded) frames, peak \(String(format: "%.3f", peak))\(peak == 0 ? " — SILENT, nothing was playing?" : "")")
    exit(0)
}

dispatchMain()
