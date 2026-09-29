import AVFoundation
import CoreGraphics
import Foundation
import ImageIO

// H.264 + AAC writer shared by the videos: frames are drawn by a callback
// into a top-left canvas backed by the pixel buffer, audio comes finished.

func writePNG(_ img: CGImage, _ path: String) {
    let d = CGImageDestinationCreateWithURL(URL(fileURLWithPath: path) as CFURL, "public.png" as CFString, 1, nil)!
    CGImageDestinationAddImage(d, img, nil); CGImageDestinationFinalize(d)
}

/// Renders single frames to PNGs (for checking), named by their time.
func writeStills(_ times: [Double], dir: String, draw frame: (Double, CGContext) -> Void) {
    try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
    for t in times {
        let c = canvas(W, H)
        frame(t, c)
        writePNG(c.makeImage()!, "\(dir)/\(String(format: "%05.2f", t)).png")
        print("still \(t)")
    }
}

func encodeVideo(to outPath: String, seconds: Double, audio: (L: [Float], R: [Float]), bitrate: Int = 12_000_000,
                 draw frame: (Double, CGContext) -> Void) {
    try? FileManager.default.removeItem(atPath: outPath)
    try? FileManager.default.createDirectory(at: URL(fileURLWithPath: outPath).deletingLastPathComponent(),
                                             withIntermediateDirectories: true)
    let writer = try! AVAssetWriter(outputURL: URL(fileURLWithPath: outPath), fileType: .mp4)
    let vIn = AVAssetWriterInput(mediaType: .video, outputSettings: [
        AVVideoCodecKey: AVVideoCodecType.h264, AVVideoWidthKey: W, AVVideoHeightKey: H,
        AVVideoCompressionPropertiesKey: [
            AVVideoAverageBitRateKey: bitrate,
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
        for i in 0..<n where start + i < audio.L.count { inter[2 * i] = audio.L[start + i]; inter[2 * i + 1] = audio.R[start + i] }
        let bytes = n * 8
        var block: CMBlockBuffer?
        CMBlockBufferCreateWithMemoryBlock(allocator: kCFAllocatorDefault, memoryBlock: nil, blockLength: bytes,
                                           blockAllocator: kCFAllocatorDefault, customBlockSource: nil, offsetToData: 0,
                                           dataLength: bytes, flags: 0, blockBufferOut: &block)
        inter.withUnsafeBytes {
            _ = CMBlockBufferReplaceDataBytes(with: $0.baseAddress!, blockBuffer: block!, offsetIntoDestination: 0, dataLength: bytes)
        }
        var sb: CMSampleBuffer?
        CMAudioSampleBufferCreateReadyWithPacketDescriptions(allocator: kCFAllocatorDefault, dataBuffer: block!,
                                                             formatDescription: audioFormat!, sampleCount: n,
                                                             presentationTimeStamp: CMTime(value: CMTimeValue(start), timescale: CMTimeScale(SR)),
                                                             packetDescriptions: nil, sampleBufferOut: &sb)
        return sb!
    }

    let frames = Int(seconds * Double(FPS)), perFrame = SR / FPS
    var vf = 0, af = 0
    let started = Date()
    while vf < frames || af < frames {
        var progressed = false
        if vf < frames && vIn.isReadyForMoreMediaData {
            var pb: CVPixelBuffer?
            CVPixelBufferPoolCreatePixelBuffer(nil, adaptor.pixelBufferPool!, &pb)
            CVPixelBufferLockBaseAddress(pb!, [])
            let c = canvas(W, H, data: CVPixelBufferGetBaseAddress(pb!), bytesPerRow: CVPixelBufferGetBytesPerRow(pb!))
            frame(Double(vf) / Double(FPS), c)
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
}
