import AVFoundation
import CoreImage
import Foundation
import Vision

// MARK: - Stabilization data

struct StabilizationData: Sendable {
    /// Per-frame corrective affine transform
    let transforms: [CGAffineTransform]
    /// Source URL for identification
    let sourceURL: URL
}

// MARK: - Stabilizer engine

enum Stabilizer {
    /// Maximum frames to analyze (skip factor for speed)
    private static let maxAnalyzeFrames = 200
    /// Minimum clip duration to bother stabilizing
    private static let minDurationSeconds: Double = 0.5

    /// Pre-compute per-frame corrective transforms for a video clip.
    /// Returns nil if stabilization is not needed or not possible.
    static func analyze(clip: Clip, sourceURL: URL, fps: Int) async -> StabilizationData? {
        let duration = Double(clip.durationFrames) / Double(fps)
        guard duration >= minDurationSeconds else { return nil }

        let asset = AVURLAsset(url: sourceURL)
        guard let videoTrack = try? await asset.loadTracks(withMediaType: .video).first else { return nil }

        let reader: AVAssetReader
        do { reader = try AVAssetReader(asset: asset) } catch { return nil }

        let outputSettings: [String: Any] = [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
            kCVPixelBufferWidthKey as String: 320,
            kCVPixelBufferHeightKey as String: 180,
        ]
        let output = AVAssetReaderTrackOutput(track: videoTrack, outputSettings: outputSettings)
        guard reader.canAdd(output) else { return nil }
        reader.add(output)

        let startTime = CMTime(seconds: Double(clip.trimStartFrame) / Double(fps), preferredTimescale: 600)
        reader.timeRange = CMTimeRange(start: startTime, duration: asset.duration - startTime)
        guard reader.startReading() else { return nil }

        var sampleBuffers: [CMSampleBuffer] = []
        let skipFrames = max(1, Int(duration * Double(fps) / Double(maxAnalyzeFrames)))
        var frameIndex = 0
        while let sample = output.copyNextSampleBuffer() {
            if frameIndex % skipFrames == 0 {
                sampleBuffers.append(sample)
            }
            frameIndex += 1
            if sampleBuffers.count >= maxAnalyzeFrames { break }
        }

        guard sampleBuffers.count >= 2 else { return nil }

        // Vision translation registration
        var transforms: [CGAffineTransform] = []
        var cumulative = CGAffineTransform.identity

        let requestHandler = VNSequenceRequestHandler()
        var previousBuffer = sampleBuffers[0]

        // First frame is identity
        transforms.append(cumulative)

        for i in 1..<sampleBuffers.count {
            let currentBuffer = sampleBuffers[i]
            let request = VNTranslationalImageRegistrationRequest(targetedCMSampleBuffer: currentBuffer)
            do {
                try requestHandler.perform([request], on: previousBuffer)
                if let alignment = request.results?.first as? VNImageTranslationAlignmentObservation {
                    let t = alignment.alignmentTransform
                    // Compensate the motion: subtract the detected translation
                    let correction = CGAffineTransform(translationX: -t.tx, y: -t.ty)
                    cumulative = cumulative.concatenating(correction)
                }
            } catch {
                // Keep previous transform on failure
            }
            transforms.append(cumulative)
            previousBuffer = currentBuffer
        }

        // Interpolate to cover all frames of the clip
        let totalFrames = clip.durationFrames
        let analyzedCount = transforms.count
        var fullTransforms: [CGAffineTransform] = []
        fullTransforms.reserveCapacity(totalFrames)

        for frame in 0..<totalFrames {
            let t = Double(frame) / Double(max(1, totalFrames - 1))
            let srcIdx = t * Double(analyzedCount - 1)
            let lo = Int(srcIdx)
            let hi = min(lo + 1, analyzedCount - 1)
            let frac = srcIdx - Double(lo)

            let a = transforms[lo]
            let b = transforms[hi]
            let tx = a.tx + (b.tx - a.tx) * frac
            let ty = a.ty + (b.ty - a.ty) * frac
            fullTransforms.append(CGAffineTransform(translationX: tx, y: ty))
        }

        return StabilizationData(transforms: fullTransforms, sourceURL: sourceURL)
    }

    /// Apply stabilizing transform to a CIImage for the given frame offset.
    static func apply(to image: CIImage, data: StabilizationData,
                      frameOffset: Int, extent: CGRect) -> CIImage {
        let idx = min(frameOffset, data.transforms.count - 1)
        let transform = data.transforms[idx]
        return image.transformed(by: transform)
    }
}
