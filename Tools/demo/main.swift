// Tools/demo — renders the thock demo video: a 3D laptop (SceneKit) with the
// real app on its screen, sweeping camera moves, original synthesised music
// and the real pack sounds in sync with every keystroke. 1920x1080, 30 fps,
// H.264 + AAC, ~35 s. Apple frameworks only.
//
//   swift build -c release && .build/release/thock --render-popover dist/popover
//   swiftc -O Tools/demo/*.swift -o /tmp/demo && /tmp/demo dist/thock-demo.mp4
//   /tmp/demo --stills 5.5,12,20 dist/stills      (single frames for checking)
//
// Run from the repo root (reads packs/, mouse-packs/, site/fonts/, dist/popover/).
import AVFoundation
import CoreGraphics
import Foundation
import ImageIO

registerFonts()
buildTimeline()
let args = Array(CommandLine.arguments.dropFirst())
let popDir = "dist/popover"
guard FileManager.default.fileExists(atPath: popDir + "/statusicon.png") else {
    print("demo: render the popover first: .build/release/thock --render-popover \(popDir)")
    exit(1)
}
let screen = Screen(popoverDir: popDir)
let stage = Stage(screen: screen)

func compose(_ t: Double, into c: CGContext) {
    draw(c, stage.frame(t), in: CGRect(x: 0, y: 0, width: W, height: H))
    overlay(c, t)
}
func writePNG(_ img: CGImage, _ path: String) {
    let d = CGImageDestinationCreateWithURL(URL(fileURLWithPath: path) as CFURL, "public.png" as CFString, 1, nil)!
    CGImageDestinationAddImage(d, img, nil); CGImageDestinationFinalize(d)
}

if args.first == "--stills" {
    let times = args[1].split(separator: ",").compactMap { Double($0) }
    let dir = args.count > 2 ? args[2] : "dist/stills"
    try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
    for t in times {
        let c = canvas(W, H)
        compose(t, into: c)
        writePNG(c.makeImage()!, "\(dir)/\(String(format: "%05.2f", t)).png")
        print("still \(t)")
    }
    exit(0)
}
let outPath = args.first ?? "dist/thock-demo.mp4"

// MARK: sound

let packs = packInfos.map { Pack($0.id, $0.name) }
let mouseDown = loadMono("mouse-packs/mx-master-3s/down.wav"), mouseUp = loadMono("mouse-packs/mx-master-3s/up.wav")
let mixer = Mixer(seconds: total)
let codes: [String: Int] = ["space": 57, "shiftL": 42, ".": 52, ",": 51, "'": 40]
for s in strokes {
    let code = codes[s.key] ?? scan[Character(s.key.lowercased())] ?? 30
    let p = packs[packAt(s.t)]
    let pan = Double(stage.keyPos(s.key).x) / 0.13 * 0.45
    let db = -20 + 20 * s.force, cutoff: Double? = s.force > 0.95 ? nil : 900 * pow(22, s.force)
    let rate = rng.range(0.975, 1.025)
    mixer.play(p.press(code), at: s.t, db: db, pan: pan, cutoff: cutoff, rate: rate)
    mixer.play(p.release(code), at: s.t + rng.range(0.08, 0.11), db: db - 4, pan: pan, cutoff: cutoff, rate: rate)
}
for k in clicks {
    let db = -12 + 12 * k.force
    mixer.play(mouseDown, at: k.t, db: db, pan: 0.1, rate: rng.range(0.98, 1.02))
    mixer.play(mouseUp, at: k.t + 0.08, db: db - 3, pan: 0.1)
}
let music = Music(seconds: total)
music.compose()
// music sits under the keys, and steps well back in the key-force bars so light taps stay audible
for i in 0..<min(mixer.n, music.n) {
    let t = Double(i) / Double(SR)
    let breakdown = smooth((t - at(7) + 0.15) / 0.3) * (1 - smooth((t - at(9) + 0.05) / 0.1))
    let g = 0.2 * (1 - 0.72 * breakdown)
    mixer.muL[i] = Float(music.L[i] * g); mixer.muR[i] = Float(music.R[i] * g)
}
let (outL, outR) = mixer.master()

// MARK: encode

try? FileManager.default.removeItem(atPath: outPath)
try? FileManager.default.createDirectory(at: URL(fileURLWithPath: outPath).deletingLastPathComponent(), withIntermediateDirectories: true)
let writer = try! AVAssetWriter(outputURL: URL(fileURLWithPath: outPath), fileType: .mp4)
let vIn = AVAssetWriterInput(mediaType: .video, outputSettings: [
    AVVideoCodecKey: AVVideoCodecType.h264, AVVideoWidthKey: W, AVVideoHeightKey: H,
    AVVideoCompressionPropertiesKey: [
        AVVideoAverageBitRateKey: 12_000_000,
        AVVideoProfileLevelKey: AVVideoProfileLevelH264HighAutoLevel,
        AVVideoMaxKeyFrameIntervalKey: FPS,
    ],
    AVVideoColorPropertiesKey: [
        AVVideoColorPrimariesKey: AVVideoColorPrimaries_ITU_R_709_2,
        AVVideoTransferFunctionKey: AVVideoTransferFunction_ITU_R_709_2,
        AVVideoYCbCrMatrixKey: AVVideoYCbCrMatrix_ITU_R_709_2,
    ],
])
vIn.expectsMediaDataInRealTime = false
let adaptor = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: vIn, sourcePixelBufferAttributes: [
    kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
    kCVPixelBufferWidthKey as String: W, kCVPixelBufferHeightKey as String: H,
])
let aIn = AVAssetWriterInput(mediaType: .audio, outputSettings: [
    AVFormatIDKey: kAudioFormatMPEG4AAC, AVSampleRateKey: SR, AVNumberOfChannelsKey: 2, AVEncoderBitRateKey: 256_000,
])
aIn.expectsMediaDataInRealTime = false
writer.add(vIn); writer.add(aIn)
guard writer.startWriting() else { fatalError("writer: \(String(describing: writer.error))") }
writer.startSession(atSourceTime: .zero)

var asbd = AudioStreamBasicDescription(mSampleRate: Double(SR), mFormatID: kAudioFormatLinearPCM,
                                       mFormatFlags: kAudioFormatFlagIsFloat | kAudioFormatFlagIsPacked,
                                       mBytesPerPacket: 8, mFramesPerPacket: 1, mBytesPerFrame: 8,
                                       mChannelsPerFrame: 2, mBitsPerChannel: 32, mReserved: 0)
var audioFormat: CMAudioFormatDescription?
CMAudioFormatDescriptionCreate(allocator: kCFAllocatorDefault, asbd: &asbd, layoutSize: 0, layout: nil,
                               magicCookieSize: 0, magicCookie: nil, extensions: nil, formatDescriptionOut: &audioFormat)
func audioChunk(_ start: Int, _ n: Int) -> CMSampleBuffer {
    var inter = [Float](repeating: 0, count: n * 2)
    for i in 0..<n where start + i < outL.count { inter[2 * i] = outL[start + i]; inter[2 * i + 1] = outR[start + i] }
    let bytes = n * 8
    var block: CMBlockBuffer?
    CMBlockBufferCreateWithMemoryBlock(allocator: kCFAllocatorDefault, memoryBlock: nil, blockLength: bytes,
                                       blockAllocator: kCFAllocatorDefault, customBlockSource: nil, offsetToData: 0,
                                       dataLength: bytes, flags: 0, blockBufferOut: &block)
    inter.withUnsafeBytes { _ = CMBlockBufferReplaceDataBytes(with: $0.baseAddress!, blockBuffer: block!, offsetIntoDestination: 0, dataLength: bytes) }
    var sb: CMSampleBuffer?
    CMAudioSampleBufferCreateReadyWithPacketDescriptions(allocator: kCFAllocatorDefault, dataBuffer: block!,
                                                         formatDescription: audioFormat!, sampleCount: n,
                                                         presentationTimeStamp: CMTime(value: CMTimeValue(start), timescale: CMTimeScale(SR)),
                                                         packetDescriptions: nil, sampleBufferOut: &sb)
    return sb!
}

let frames = Int(total * Double(FPS)), perFrame = SR / FPS
var vf = 0, af = 0
let started = Date()
while vf < frames || af < frames {
    var progressed = false
    if vf < frames && vIn.isReadyForMoreMediaData {
        var pb: CVPixelBuffer?
        CVPixelBufferPoolCreatePixelBuffer(nil, adaptor.pixelBufferPool!, &pb)
        CVPixelBufferLockBaseAddress(pb!, [])
        let c = canvas(W, H, data: CVPixelBufferGetBaseAddress(pb!), bytesPerRow: CVPixelBufferGetBytesPerRow(pb!))
        compose(Double(vf) / Double(FPS), into: c)
        CVPixelBufferUnlockBaseAddress(pb!, [])
        adaptor.append(pb!, withPresentationTime: CMTime(value: CMTimeValue(vf), timescale: CMTimeScale(FPS)))
        vf += 1; progressed = true
        if vf % 60 == 0 { print("frame \(vf)/\(frames)  \(Int(Date().timeIntervalSince(started))) s") }
        if vf == frames { vIn.markAsFinished() }
    }
    if af < frames && aIn.isReadyForMoreMediaData {
        aIn.append(audioChunk(af * perFrame, perFrame))
        af += 1; progressed = true
        if af == frames { aIn.markAsFinished() }
    }
    if !progressed { usleep(500) }
}
let done = DispatchSemaphore(value: 0)
writer.finishWriting { done.signal() }
done.wait()
guard writer.status == .completed else { fatalError("writer: \(String(describing: writer.error))") }
let poster = canvas(W, H)
compose(at(14, 3), into: poster)
writePNG(poster.makeImage()!, outPath.replacingOccurrences(of: ".mp4", with: "-poster.png"))
print("wrote \(outPath): \(W)x\(H) \(FPS) fps, \(String(format: "%.1f", total)) s")
