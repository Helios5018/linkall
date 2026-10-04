import AppKit
import Vision
import LinkRecordCore

/// Stateless: cached text is supplied from a still-existing History record, never a global cache.
enum ScreenOCR {
    static let bandHeight = 1024
    static let overlap = 96

    static func fingerprint(_ image: CGImage) -> String? {
        var rgba = Data(count: image.width * image.height * 4)
        let drawn = rgba.withUnsafeMutableBytes { bytes -> Bool in
            guard let space = CGColorSpace(name: CGColorSpace.sRGB), let context = CGContext(data: bytes.baseAddress, width: image.width, height: image.height, bitsPerComponent: 8, bytesPerRow: image.width * 4, space: space, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue | CGBitmapInfo.byteOrder32Big.rawValue) else { return false }
            context.setBlendMode(.copy)
            context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
            return true
        }
        return drawn ? ScreenshotFingerprint.make(width: image.width, height: image.height, rgba: rgba) : nil
    }

    static func recognize(_ image: CGImage, previous: ScreenTextSnapshot? = nil) -> ScreenTextSnapshot {
        let started = ProcessInfo.processInfo.systemUptime
        let compatible = previous?.version == ScreenTextSnapshot.currentVersion && previous?.imageWidth == image.width && previous?.imageHeight == image.height
        let cache = compatible ? previous!.regions : []
        var regions: [ScreenOCRRegion] = [], recognized = 0, reused = 0
        for (index, top) in stride(from: 0, to: image.height, by: bandHeight).enumerated() {
            // Full-width bands avoid cutting words horizontally. Overlap supplies line context.
            let cropTop = max(0, top - overlap), bottom = min(image.height, top + bandHeight + overlap)
            let rect = CGRect(x: 0, y: cropTop, width: image.width, height: bottom - cropTop)
            guard let crop = image.cropping(to: rect), let hash = fingerprint(crop) else {
                regions.append(.init(index: index, fingerprint: "", blocks: [], complete: false)); continue
            }
            if let old = cache.first(where: { $0.index == index && $0.complete && $0.fingerprint == hash }) {
                regions.append(old); reused += 1; continue
            }
            recognized += 1
            let request = VNRecognizeTextRequest()
            request.recognitionLevel = .accurate
            request.recognitionLanguages = ["zh-Hans", "en-US"]
            request.usesLanguageCorrection = false
            do {
                try VNImageRequestHandler(cgImage: crop).perform([request])
                let blocks = (request.results ?? []).compactMap { observation -> ScreenTextBlock? in
                    guard let candidate = observation.topCandidates(1).first else { return nil }
                    let box = observation.boundingBox
                    let y = Double(cropTop) + (1 - box.maxY) * Double(crop.height)
                    let height = box.height * Double(crop.height)
                    let center = y + height / 2
                    guard center >= Double(top), center < Double(min(image.height, top + bandHeight)) else { return nil }
                    return ScreenTextBlock(text: candidate.string, bounds: .init(x: box.minX, y: y / Double(image.height), width: box.width, height: height / Double(image.height)), source: .vision, confidence: candidate.confidence)
                }
                regions.append(.init(index: index, fingerprint: hash, blocks: blocks, complete: true))
            } catch { regions.append(.init(index: index, fingerprint: hash, blocks: [], complete: false)) }
        }
        return .init(imageWidth: image.width, imageHeight: image.height, regions: regions, recognizedRegions: recognized, reusedRegions: reused, ocrMilliseconds: (ProcessInfo.processInfo.systemUptime - started) * 1000)
    }
}
