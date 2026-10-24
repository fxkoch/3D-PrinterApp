import SliceKit
import UIKit
import Vision

/// UIImage → brightness values (and the subject mask from the system's "lift subject" if it finds one).
enum PhotoPrep {
    /// Longest side of the working image in pixels (the shape is built at about 180 px anyway).
    private static let side = 360

    static func prepare(_ image: UIImage) async -> GrayImage {
        await Task.detached(priority: .userInitiated) { () -> GrayImage in
            let scale = min(1, CGFloat(side) / max(image.size.width, image.size.height))
            let size = CGSize(width: max(1, (image.size.width * scale).rounded()), height: max(1, (image.size.height * scale).rounded()))
            let format = UIGraphicsImageRendererFormat()
            format.scale = 1
            format.opaque = true
            let normalized = UIGraphicsImageRenderer(size: size, format: format).image { _ in image.draw(in: CGRect(origin: .zero, size: size)) }
            let w = Int(size.width), h = Int(size.height)
            var gray = [Float](repeating: 0, count: w * h)
            if let cg = normalized.cgImage {
                var bytes = [UInt8](repeating: 0, count: w * h * 4)
                bytes.withUnsafeMutableBytes { raw in
                    if let ctx = CGContext(data: raw.baseAddress, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4,
                                           space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) {
                        ctx.draw(cg, in: CGRect(x: 0, y: 0, width: w, height: h))
                    }
                }
                for i in 0..<(w * h) {
                    gray[i] = (0.299 * Float(bytes[i * 4]) + 0.587 * Float(bytes[i * 4 + 1]) + 0.114 * Float(bytes[i * 4 + 2])) / 255
                }
            }
            return GrayImage(width: w, height: h, pixels: gray, subject: subjectMask(normalized, w, h))
        }.value
    }

    /// The foreground object as the system sees it (iOS 17 "subject lifting"); nil when nothing is found or it is not available.
    private static func subjectMask(_ image: UIImage, _ w: Int, _ h: Int) -> [Float]? {
        guard let cg = image.cgImage else { return nil }
        let request = VNGenerateForegroundInstanceMaskRequest()
        let handler = VNImageRequestHandler(cgImage: cg, options: [:])
        do {
            try handler.perform([request])
            guard let observation = request.results?.first, !observation.allInstances.isEmpty else { return nil }
            let buffer = try observation.generateScaledMaskForImage(forInstances: observation.allInstances, from: handler)
            CVPixelBufferLockBaseAddress(buffer, .readOnly)
            defer { CVPixelBufferUnlockBaseAddress(buffer, .readOnly) }
            let bw = CVPixelBufferGetWidth(buffer), bh = CVPixelBufferGetHeight(buffer)
            guard let base = CVPixelBufferGetBaseAddress(buffer) else { return nil }
            let stride = CVPixelBufferGetBytesPerRow(buffer)
            let format = CVPixelBufferGetPixelFormatType(buffer)
            var mask = [Float](repeating: 0, count: w * h)
            for y in 0..<h { for x in 0..<w {
                let sx = min(bw - 1, x * bw / w), sy = min(bh - 1, y * bh / h)
                if format == kCVPixelFormatType_OneComponent32Float {
                    mask[y * w + x] = base.advanced(by: sy * stride + sx * 4).assumingMemoryBound(to: Float.self).pointee
                } else {
                    mask[y * w + x] = Float(base.advanced(by: sy * stride + sx).assumingMemoryBound(to: UInt8.self).pointee) / 255
                }
            } }
            // A mask that covers nearly nothing or everything says nothing.
            let share = mask.reduce(0) { $0 + ($1 > 0.5 ? 1 : 0) } / Float(mask.count)
            return share > 0.02 && share < 0.95 ? mask : nil
        } catch {
            return nil
        }
    }

    /// A drawn test photo (dark star on a light table) for the UI tests.
    static func syntheticPhoto() -> UIImage {
        let size = CGSize(width: 480, height: 480)
        return UIGraphicsImageRenderer(size: size).image { ctx in
            UIColor(white: 0.93, alpha: 1).setFill()
            ctx.fill(CGRect(origin: .zero, size: size))
            let path = UIBezierPath()
            for i in 0..<10 {
                let r: CGFloat = i % 2 == 0 ? 170 : 75
                let a = CGFloat(i) / 10 * 2 * .pi - .pi / 2
                let p = CGPoint(x: 240 + r * cos(a), y: 250 + r * sin(a))
                if i == 0 { path.move(to: p) } else { path.addLine(to: p) }
            }
            path.close()
            UIColor(white: 0.12, alpha: 1).setFill()
            path.fill()
        }
    }
}
