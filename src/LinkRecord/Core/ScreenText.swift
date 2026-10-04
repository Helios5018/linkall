import Foundation
import CoreGraphics

/// All rectangles use normalized screenshot coordinates, with the origin at the top left.
public struct ScreenRect: Codable, Equatable, Sendable {
    public var x: Double, y: Double, width: Double, height: Double
    public init(x: Double, y: Double, width: Double, height: Double) {
        self.x = x; self.y = y; self.width = width; self.height = height
    }
    public var cgRect: CGRect { CGRect(x: x, y: y, width: width, height: height) }
}

public struct ScreenTextBlock: Codable, Equatable, Sendable {
    public enum Source: String, Codable, Sendable { case vision, accessibility }
    public var text: String
    public var bounds: ScreenRect
    public var source: Source
    public var confidence: Float?
    public var role: String?
    /// Bounded tree path, not an inferred speaker or conversation identity.
    public var path: String?
    public init(text: String, bounds: ScreenRect, source: Source, confidence: Float? = nil, role: String? = nil, path: String? = nil) {
        self.text = text; self.bounds = bounds; self.source = source
        self.confidence = confidence; self.role = role; self.path = path
    }
}

public struct ScreenOCRRegion: Codable, Equatable, Sendable {
    public var index: Int
    public var fingerprint: String
    public var blocks: [ScreenTextBlock]
    public var complete: Bool
    public init(index: Int, fingerprint: String, blocks: [ScreenTextBlock], complete: Bool) {
        self.index = index; self.fingerprint = fingerprint; self.blocks = blocks; self.complete = complete
    }
}

public struct ScreenTextSnapshot: Codable, Equatable, Sendable {
    // Bump when OCR parameters, tiling, or coordinate conventions change.
    public static let currentVersion = 1
    public var version = currentVersion
    /// Verified unobscured front-window region in this display capture. Legacy snapshots lack it.
    public var windowTextBounds: ScreenRect? = nil
    public var imageWidth: Int
    public var imageHeight: Int
    public var regions: [ScreenOCRRegion]
    public var accessibility: [ScreenTextBlock]
    public var accessibilityStatus: String
    public var recognizedRegions: Int
    public var reusedRegions: Int
    public var ocrMilliseconds: Double
    public init(imageWidth: Int, imageHeight: Int, regions: [ScreenOCRRegion], accessibility: [ScreenTextBlock] = [], accessibilityStatus: String = "unavailable", recognizedRegions: Int, reusedRegions: Int, ocrMilliseconds: Double) {
        self.imageWidth = imageWidth; self.imageHeight = imageHeight; self.regions = regions
        self.accessibility = accessibility; self.accessibilityStatus = accessibilityStatus
        self.recognizedRegions = recognizedRegions; self.reusedRegions = reusedRegions; self.ocrMilliseconds = ocrMilliseconds
    }
    public var ocrComplete: Bool { !regions.isEmpty && regions.allSatisfy(\.complete) }
    public var ocrBlocks: [ScreenTextBlock] { regions.flatMap(\.blocks) }
    /// Prefer direct visible text on the same line. Raw OCR remains unchanged in regions.
    public var readingBlocks: [ScreenTextBlock] {
        func key(_ text: String) -> String { text.filter { !$0.isWhitespace } }
        let direct = accessibility.map { (key($0.text), $0.bounds.cgRect) }
        let ocr = ocrBlocks.filter { block in
            !direct.contains { text, rect in
                let box = block.bounds.cgRect, overlap = rect.intersection(block.bounds.cgRect)
                guard !overlap.isNull, overlap.width * overlap.height > 0 else { return false }
                if text == key(block.text) { return true }
                return rect.height <= box.height * 2.5 && abs(rect.midY - box.midY) <= max(rect.height, box.height) * 0.5
                    && overlap.width * overlap.height >= box.width * box.height * 0.85
            }
        }
        // Cluster baselines before sorting horizontally. Exact y sorting scrambles fragments
        // of one line when recognition boxes differ vertically by a pixel or two.
        var rows: [[ScreenTextBlock]] = []
        for block in (ocr + accessibility).sorted(by: { $0.bounds.cgRect.midY < $1.bounds.cgRect.midY }) {
            if let last = rows.last, let anchor = last.first,
               abs(anchor.bounds.cgRect.midY - block.bounds.cgRect.midY) <= min(anchor.bounds.height, block.bounds.height) * 0.45 {
                rows[rows.count - 1].append(block)
            } else { rows.append([block]) }
        }
        return rows.flatMap { $0.sorted { $0.bounds.x < $1.bounds.x } }
    }
    public var text: String { readingBlocks.map(\.text).joined(separator: "\n") }
}

public enum ScreenVisibility {
    /// Fail closed for partially clipped or occluded text; never read hidden text to trim it later.
    public static func permits(_ frame: CGRect, inside viewport: CGRect, occluders: [CGRect]) -> Bool {
        frame.width > 0 && frame.height > 0 && viewport.contains(frame)
            && !occluders.contains { $0.intersects(frame) }
    }
}
