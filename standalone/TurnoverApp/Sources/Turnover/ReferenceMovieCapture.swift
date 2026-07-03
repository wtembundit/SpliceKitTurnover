import AVFoundation
import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

enum ReferenceMovieCapture {
    struct CaptureFailure: LocalizedError {
        let message: String
        var errorDescription: String? { message }
    }

    final class Session: @unchecked Sendable {
        private let generator: AVAssetImageGenerator
        let duration: Double

        init(movieURL: URL) async throws {
            let asset = AVURLAsset(url: movieURL)
            duration = try await asset.load(.duration).seconds
            guard duration.isFinite, duration > 0 else {
                throw CaptureFailure(message: "The selected reference movie has no readable duration.")
            }
            generator = AVAssetImageGenerator(asset: asset)
            generator.appliesPreferredTrackTransform = true
            generator.requestedTimeToleranceBefore = .zero
            generator.requestedTimeToleranceAfter = .zero
        }

        func captureFrame(seconds: Double, outputURL: URL, thumbnail: Bool = false) async throws -> Double {
            guard seconds >= 0, seconds < duration else {
                throw CaptureFailure(message: String(format: "Marker time %.3fs is outside the reference movie duration %.3fs.", seconds, duration))
            }
            let requestedTime = CMTime(seconds: seconds, preferredTimescale: 60_000)
            let result = try await generator.image(at: requestedTime)
            let image = thumbnail ? try makeThumbnail(from: result.image, maxWidth: 960) : result.image
            try write(image: image, to: outputURL, jpeg: thumbnail)
            return result.actualTime.seconds
        }
    }

    static func captureFrame(movieURL: URL, seconds: Double, outputURL: URL) async throws -> Double {
        let session = try await Session(movieURL: movieURL)
        return try await session.captureFrame(seconds: seconds, outputURL: outputURL)
    }

    private static func makeThumbnail(from image: CGImage, maxWidth: Int) throws -> CGImage {
        let sourceWidth = CGFloat(image.width)
        let sourceHeight = CGFloat(image.height)
        let targetAspect: CGFloat = 16.0 / 9.0
        let sourceAspect = sourceWidth / sourceHeight
        let cropRect: CGRect
        if sourceAspect > targetAspect {
            let width = sourceHeight * targetAspect
            cropRect = CGRect(x: (sourceWidth - width) / 2, y: 0, width: width, height: sourceHeight)
        } else {
            let height = sourceWidth / targetAspect
            cropRect = CGRect(x: 0, y: (sourceHeight - height) / 2, width: sourceWidth, height: height)
        }
        guard let cropped = image.cropping(to: cropRect.integral) else {
            throw CaptureFailure(message: "Could not crop a reference frame to 16:9.")
        }
        let width = min(maxWidth, cropped.width)
        let height = max(1, Int((Double(width) * 9.0 / 16.0).rounded()))
        guard let context = CGContext(
            data: nil,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else {
            throw CaptureFailure(message: "Could not create the thumbnail canvas.")
        }
        context.interpolationQuality = .high
        context.draw(cropped, in: CGRect(x: 0, y: 0, width: width, height: height))
        guard let thumbnail = context.makeImage() else {
            throw CaptureFailure(message: "Could not render the thumbnail.")
        }
        return thumbnail
    }

    private static func write(image: CGImage, to outputURL: URL, jpeg: Bool) throws {
        try FileManager.default.createDirectory(at: outputURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        let type = jpeg ? UTType.jpeg.identifier : UTType.png.identifier
        guard let destination = CGImageDestinationCreateWithURL(outputURL as CFURL, type as CFString, 1, nil) else {
            throw CaptureFailure(message: "Could not create the image output.")
        }
        let properties = jpeg
            ? [kCGImageDestinationLossyCompressionQuality as String: 0.9] as CFDictionary
            : nil
        CGImageDestinationAddImage(destination, image, properties)
        guard CGImageDestinationFinalize(destination) else {
            throw CaptureFailure(message: "Could not write the reference movie frame.")
        }
    }
}
