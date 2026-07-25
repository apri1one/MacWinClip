import AVFoundation
import CoreVideo
import Foundation

enum FixtureError: Error {
    case invalidArguments
    case writerFailed
}

func writeVideo(to url: URL, fileType: AVFileType, color: UInt32) throws {
    let writer = try AVAssetWriter(outputURL: url, fileType: fileType)
    let input = AVAssetWriterInput(
        mediaType: .video,
        outputSettings: [
            AVVideoCodecKey: AVVideoCodecType.h264,
            AVVideoWidthKey: 32,
            AVVideoHeightKey: 32
        ]
    )
    let adaptor = AVAssetWriterInputPixelBufferAdaptor(
        assetWriterInput: input,
        sourcePixelBufferAttributes: [
            kCVPixelBufferPixelFormatTypeKey as String:
                kCVPixelFormatType_32BGRA,
            kCVPixelBufferWidthKey as String: 32,
            kCVPixelBufferHeightKey as String: 32
        ]
    )
    guard writer.canAdd(input) else {
        throw FixtureError.writerFailed
    }
    writer.add(input)
    guard writer.startWriting() else {
        throw writer.error ?? FixtureError.writerFailed
    }
    writer.startSession(atSourceTime: .zero)
    guard
        let pool = adaptor.pixelBufferPool
    else {
        throw FixtureError.writerFailed
    }
    var optionalBuffer: CVPixelBuffer?
    guard
        CVPixelBufferPoolCreatePixelBuffer(
            nil,
            pool,
            &optionalBuffer
        ) == kCVReturnSuccess,
        let buffer = optionalBuffer
    else {
        throw FixtureError.writerFailed
    }
    CVPixelBufferLockBaseAddress(buffer, [])
    if let base = CVPixelBufferGetBaseAddress(buffer) {
        let pixels = base.bindMemory(
            to: UInt32.self,
            capacity: 32 * 32
        )
        for index in 0..<(32 * 32) {
            pixels[index] = color
        }
    }
    CVPixelBufferUnlockBaseAddress(buffer, [])
    while !input.isReadyForMoreMediaData {
        Thread.sleep(forTimeInterval: 0.01)
    }
    guard adaptor.append(buffer, withPresentationTime: .zero) else {
        throw writer.error ?? FixtureError.writerFailed
    }
    input.markAsFinished()
    let semaphore = DispatchSemaphore(value: 0)
    writer.finishWriting {
        semaphore.signal()
    }
    _ = semaphore.wait(timeout: .now() + 30)
    guard writer.status == .completed else {
        throw writer.error ?? FixtureError.writerFailed
    }
}

guard CommandLine.arguments.count == 2 else {
    throw FixtureError.invalidArguments
}
let root = URL(
    fileURLWithPath: CommandLine.arguments[1],
    isDirectory: true
)
try FileManager.default.createDirectory(
    at: root,
    withIntermediateDirectories: false
)
try writeVideo(
    to: root.appendingPathComponent("generated-a.mov"),
    fileType: .mov,
    color: 0xff204060
)
try writeVideo(
    to: root.appendingPathComponent("generated-b.mov"),
    fileType: .mov,
    color: 0xff608020
)
try writeVideo(
    to: root.appendingPathComponent("generated-c.mp4"),
    fileType: .mp4,
    color: 0xff802060
)
