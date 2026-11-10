import AVFoundation
import Foundation
import Observation
import RealityKit
import SliceKit
import SwiftUI

/// From photos or a video to a printable mesh: capture (guided with LiDAR, or from the photo library), reconstruction with
/// Apple's Object Capture on the device, then cleanup (close holes, remove specks) and the real size.
@MainActor
@Observable
final class ScanModel {
    enum Stage: Equatable {
        case start, capturing, processing(String, Double), review, failed(String)
    }

    var stage: Stage = .start
    var session: ObjectCaptureSession?
    var mesh: TriangleMesh?
    var report: MeshRepair.Report?
    var imageCount = 0

    private let work: URL
    private var imagesDir: URL { work.appendingPathComponent("Images", isDirectory: true) }
    private var snapshotDir: URL { work.appendingPathComponent("Snapshots", isDirectory: true) }
    private var reconstruction: Task<Void, Never>?

    init() {
        work = FileManager.default.temporaryDirectory.appendingPathComponent("Scan-\(UUID().uuidString)", isDirectory: true)
    }

    deinit { try? FileManager.default.removeItem(at: work) }

    /// Guided capture needs a LiDAR iPhone (A14 or newer).
    static var guidedCaptureSupported: Bool { ObjectCaptureSession.isSupported }
    /// Reconstruction from existing photos needs the same class of device.
    static var reconstructionSupported: Bool { PhotogrammetrySession.isSupported }

    // MARK: Guided capture

    func startGuidedCapture() {
        do {
            try FileManager.default.createDirectory(at: imagesDir, withIntermediateDirectories: true)
            try FileManager.default.createDirectory(at: snapshotDir, withIntermediateDirectories: true)
            let s = ObjectCaptureSession()
            var configuration = ObjectCaptureSession.Configuration()
            configuration.checkpointDirectory = snapshotDir
            s.start(imagesDirectory: imagesDir, configuration: configuration)
            session = s
            stage = .capturing
        } catch {
            stage = .failed(error.localizedDescription)
        }
    }

    /// Called when the guided session has stopped capturing: continue with the reconstruction.
    func finishGuidedCapture() {
        session?.finish()
    }

    func guidedSessionEnded() {
        guard stage == .capturing else { return }
        session = nil
        reconstruct()
    }

    // MARK: Photos and videos from the library

    func importMedia(images: [Data], videos: [URL]) {
        stage = .processing("Bilder vorbereiten …", 0)
        reconstruction = Task {
            do {
                try FileManager.default.createDirectory(at: imagesDir, withIntermediateDirectories: true)
                var n = 0
                for data in images { try data.write(to: imagesDir.appendingPathComponent(String(format: "foto-%04d.jpg", n))); n += 1 }
                for video in videos { n += try await extractFrames(from: video, startingAt: n) }
                imageCount = n
                guard n >= 20 else { stage = .failed("Zu wenige Bilder (\(n)). Für ein brauchbares Modell sind mindestens 20 Fotos nötig, besser 40–100 rund um das Objekt."); return }
                reconstruct()
            } catch {
                stage = .failed(error.localizedDescription)
            }
        }
    }

    /// One frame every 0.4 s, at most 150.
    private func extractFrames(from url: URL, startingAt start: Int) async throws -> Int {
        let asset = AVURLAsset(url: url)
        let duration = try await asset.load(.duration).seconds
        let generator = AVAssetImageGenerator(asset: asset)
        generator.appliesPreferredTrackTransform = true
        generator.requestedTimeToleranceBefore = .zero
        generator.requestedTimeToleranceAfter = .zero
        let step = max(0.4, duration / 150)
        var n = 0
        var t = 0.0
        while t < duration, n < 150 {
            if let image = try? await generator.image(at: CMTime(seconds: t, preferredTimescale: 600)).image,
               let data = UIImage(cgImage: image).jpegData(compressionQuality: 0.92) {
                try data.write(to: imagesDir.appendingPathComponent(String(format: "video-%04d.jpg", start + n)))
                n += 1
            }
            t += step
        }
        return n
    }

    // MARK: Reconstruction

    func reconstruct() {
        guard Self.reconstructionSupported else {
            stage = .failed("Dieses Gerät kann die Rekonstruktion nicht selbst rechnen (nötig: iPhone oder iPad mit LiDAR-Sensor, ab A14-Chip).")
            return
        }
        stage = .processing("Modell wird berechnet – das dauert einige Minuten …", 0)
        reconstruction = Task {
            let output = work.appendingPathComponent("scan.usdz")
            do {
                try? FileManager.default.removeItem(at: output)
                try await runPhotogrammetry(detail: .reduced, output: output)
                stage = .processing("Modell aufräumen …", 1)
                let loaded = try ModelIOMesh.load(url: output)
                let (repaired, report) = MeshRepair.repair(loaded)
                mesh = repaired.placedOnBed(center: (0, 0))
                self.report = report
                stage = .review
            } catch {
                if Task.isCancelled { stage = .start } else { stage = .failed(error.localizedDescription) }
            }
        }
    }

    private func runPhotogrammetry(detail: PhotogrammetrySession.Request.Detail, output: URL) async throws {
        var configuration = PhotogrammetrySession.Configuration()
        configuration.sampleOrdering = .unordered
        configuration.featureSensitivity = .normal
        let session = try PhotogrammetrySession(input: imagesDir, configuration: configuration)
        try session.process(requests: [.modelFile(url: output, detail: detail)])
        for try await result in session.outputs {
            switch result {
            case .requestProgress(_, let fraction): stage = .processing("Modell wird berechnet – das dauert einige Minuten …", fraction)
            case .requestError(_, let error): throw error
            case .processingCancelled: throw CancellationError()
            default: break
            }
        }
    }

    func cancel() {
        reconstruction?.cancel()
        session?.cancel()
        session = nil
        stage = .start
    }

    /// Scale the model so its longest side is `millimetres`.
    func scaleLongestSide(to millimetres: Double) {
        guard let mesh else { return }
        let size = mesh.boundingBox.size
        let longest = max(size.x, size.y, size.z)
        guard longest > 0, millimetres > 0 else { return }
        let f = millimetres / longest
        self.mesh = mesh.transformed(.scale(Vec3(f, f, f))).placedOnBed(center: (0, 0))
    }
}
