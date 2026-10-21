import AVFoundation
import CoreMedia
import Observation
import PrinterKit
import SwiftUI

/// Shows H.264 video frames (from the printer's FLV stream) with the system's hardware decoder.
final class H264Renderer {
    let layer = AVSampleBufferDisplayLayer()
    private var format: CMVideoFormatDescription?

    init() {
        layer.videoGravity = .resizeAspect
        layer.backgroundColor = UIColor.black.cgColor
    }

    func configure(sps: [UInt8], pps: [UInt8], nalLengthSize: Int) {
        var new: CMVideoFormatDescription?
        sps.withUnsafeBufferPointer { s in
            pps.withUnsafeBufferPointer { p in
                let pointers = [s.baseAddress!, p.baseAddress!]
                let sizes = [sps.count, pps.count]
                CMVideoFormatDescriptionCreateFromH264ParameterSets(allocator: nil, parameterSetCount: 2, parameterSetPointers: pointers,
                                                                    parameterSetSizes: sizes, nalUnitHeaderLength: Int32(nalLengthSize),
                                                                    formatDescriptionOut: &new)
            }
        }
        format = new
        layer.flushAndRemoveImage()
    }

    func enqueue(_ data: [UInt8], timestampMS: Int) {
        guard let format, !data.isEmpty else { return }
        if layer.status == .failed { layer.flush() }
        var block: CMBlockBuffer?
        guard CMBlockBufferCreateWithMemoryBlock(allocator: nil, memoryBlock: nil, blockLength: data.count, blockAllocator: nil,
                                                 customBlockSource: nil, offsetToData: 0, dataLength: data.count, flags: 0,
                                                 blockBufferOut: &block) == kCMBlockBufferNoErr, let block else { return }
        let copied = data.withUnsafeBytes {
            CMBlockBufferReplaceDataBytes(with: $0.baseAddress!, blockBuffer: block, offsetIntoDestination: 0, dataLength: data.count)
        }
        guard copied == kCMBlockBufferNoErr else { return }
        var timing = CMSampleTimingInfo(duration: .invalid, presentationTimeStamp: CMTime(value: CMTimeValue(timestampMS), timescale: 1000),
                                        decodeTimeStamp: .invalid)
        var size = data.count
        var sample: CMSampleBuffer?
        guard CMSampleBufferCreateReady(allocator: nil, dataBuffer: block, formatDescription: format, sampleCount: 1,
                                        sampleTimingEntryCount: 1, sampleTimingArray: &timing, sampleSizeEntryCount: 1,
                                        sampleSizeArray: &size, sampleBufferOut: &sample) == noErr, let sample else { return }
        if let attachments = CMSampleBufferGetSampleAttachmentsArray(sample, createIfNecessary: true) as? [NSMutableDictionary],
           let first = attachments.first {
            first[kCMSampleAttachmentKey_DisplayImmediately] = true   // live view: show frames as they arrive
        }
        layer.enqueue(sample)
    }
}

struct H264PlayerView: UIViewRepresentable {
    let renderer: H264Renderer

    func makeUIView(context: Context) -> PlayerUIView { PlayerUIView(layer: renderer.layer) }
    func updateUIView(_ uiView: PlayerUIView, context: Context) {}

    final class PlayerUIView: UIView {
        private let video: AVSampleBufferDisplayLayer
        init(layer: AVSampleBufferDisplayLayer) {
            video = layer
            super.init(frame: .zero)
            self.layer.addSublayer(layer)
        }
        required init?(coder: NSCoder) { fatalError() }
        override func layoutSubviews() {
            super.layoutSubviews()
            video.frame = bounds
        }
    }
}

/// Starts the printer's camera, plays its FLV stream and stops the camera again when closed.
@MainActor
@Observable
final class LiveCamera {
    enum State: Equatable {
        case idle, starting, live
        case failed(String)
    }

    private(set) var state: State = .idle
    @ObservationIgnored let renderer = H264Renderer()
    @ObservationIgnored private var task: Task<Void, Never>?
    @ObservationIgnored private var finish: (() async -> Void)?

    /// - Parameters:
    ///   - prepare: switches the printer's camera on (Anycubic needs this before the stream delivers data).
    ///   - finish: switches it off again.
    func start(streamURL: URL, prepare: @escaping () async throws -> Void, finish: @escaping () async -> Void) {
        stop()
        self.finish = finish
        state = .starting
        task = Task { [weak self] in
            try? await prepare()   // the printer answers the start command late; the stream works anyway
            for attempt in 1...3 {
                guard let self, !Task.isCancelled else { return }
                do {
                    try await self.play(streamURL)
                } catch is CancellationError {
                    return
                } catch {
                    // fall through and retry
                }
                guard !Task.isCancelled else { return }
                if attempt == 3 { self.state = .failed("Die Kamera liefert kein Bild. Läuft der Drucker und ist er erreichbar?") }
                try? await Task.sleep(nanoseconds: 1_500_000_000)
            }
        }
    }

    func stop() {
        task?.cancel()
        task = nil
        let finish = self.finish
        self.finish = nil
        if let finish { Task { await finish() } }
        if state != .idle { state = .idle }
    }

    private func play(_ url: URL) async throws {
        var request = URLRequest(url: url)
        request.timeoutInterval = 15
        let (bytes, response) = try await URLSession.shared.bytes(for: request)
        guard (response as? HTTPURLResponse)?.statusCode == 200 else { throw URLError(.badServerResponse) }
        var demux = FLVDemuxer()
        var chunk: [UInt8] = []
        chunk.reserveCapacity(4096)
        for try await byte in bytes {
            chunk.append(byte)
            guard chunk.count >= 2048 || (byte == 0 && chunk.count > 1000) else { continue }
            for event in demux.feed(chunk) {
                switch event {
                case .config(let sps, let pps, let n): renderer.configure(sps: sps, pps: pps, nalLengthSize: n)
                case .frame(let data, let ts, _):
                    renderer.enqueue(data, timestampMS: ts)
                    if state != .live { state = .live }
                }
            }
            chunk.removeAll(keepingCapacity: true)
        }
    }
}
