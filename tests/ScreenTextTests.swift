import XCTest
import AppKit
import Vision
import ScreenCaptureKit
@testable import LinkRecordCore
@testable import LinkRecordUI

final class ScreenTextTests: XCTestCase {
    private func block(_ text: String, source: ScreenTextBlock.Source = .vision, y: Double = 0.1) -> ScreenTextBlock {
        .init(text: text, bounds: .init(x: 0.1, y: y, width: 0.3, height: 0.03), source: source, confidence: source == .vision ? 0.9 : nil)
    }
    private func snapshot(_ text: String = "OCR") -> ScreenTextSnapshot {
        .init(imageWidth: 100, imageHeight: 100, regions: [.init(index: 0, fingerprint: "region", blocks: [block(text)], complete: true)], recognizedRegions: 1, reusedRegions: 0, ocrMilliseconds: 10)
    }
    func testVisibleBoundsRejectClippingOcclusionAndEmptyFrames() {
        let viewport = CGRect(x: 0, y: 0, width: 100, height: 100)
        XCTAssertTrue(ScreenVisibility.permits(CGRect(x: 10, y: 10, width: 20, height: 10), inside: viewport, occluders: []))
        XCTAssertFalse(ScreenVisibility.permits(CGRect(x: -1, y: 10, width: 20, height: 10), inside: viewport, occluders: []))
        XCTAssertFalse(ScreenVisibility.permits(CGRect(x: 10, y: 10, width: 20, height: 10), inside: viewport, occluders: [CGRect(x: 25, y: 15, width: 50, height: 50)]))
        XCTAssertFalse(ScreenVisibility.permits(.zero, inside: viewport, occluders: []))
    }
    func testMergePrefersDirectTextButKeepsRawOCRAndRepeatedTextInDifferentPositions() {
        var value = snapshot("你好")
        value.accessibility = [block("你 好", source: .accessibility)]
        XCTAssertEqual(value.readingBlocks.count, 1)
        XCTAssertEqual(value.readingBlocks.first?.source, .accessibility)
        value.accessibility = [block("您好", source: .accessibility)]
        XCTAssertEqual(value.readingBlocks.map(\.text), ["您好"])
        XCTAssertEqual(value.ocrBlocks.map(\.text), ["你好"])
        value.accessibility = [block("你好", source: .accessibility, y: 0.8)]
        XCTAssertEqual(value.readingBlocks.count, 2)
    }
    func testFragmentsWithDifferentBaselinesReadLeftToRight() {
        var value = snapshot()
        var left = block("left", y: 0.102), right = block("right", y: 0.1)
        left.bounds.x = 0.1; right.bounds.x = 0.5
        value.regions[0].blocks = [right, left, block("next", y: 0.2)]
        XCTAssertEqual(value.readingBlocks.map(\.text), ["left", "right", "next"])
    }
    func testLegacyAndStructuredRoundTrip() throws {
        var record = HistoryRecord(kind: .screenshot)
        let legacy = try JSONDecoder().decode(HistoryRecord.self, from: JSONEncoder().encode(record))
        XCTAssertNil(legacy.screenText)
        record.screenText = snapshot()
        XCTAssertEqual(try JSONDecoder().decode(HistoryRecord.self, from: JSONEncoder().encode(record)), record)
    }
    func testReuseKeepsCurrentAXAndStopsAfterSourceDeletion() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = try HistoryStore(directory: root)
        var first = HistoryRecord(kind: .screenshot, app: "editor", window: "A")
        first.screenText = snapshot(); first.screenshotFingerprint = "frame"; first.screenshotOCRComplete = true
        let saved = try XCTUnwrap(store.saveScreenshot(first, jpeg: Data([1])))
        var incoming = first; incoming.id = UUID(); incoming.date = first.date.addingTimeInterval(1)
        incoming.screenText?.accessibility = [block("current app", source: .accessibility)]
        incoming.original = incoming.screenText!.text
        let visit = try XCTUnwrap(store.saveScreenshot(incoming, jpeg: nil, reusedOCRSource: saved.id))
        XCTAssertEqual(visit.screenText?.accessibility.first?.text, "current app")
        XCTAssertEqual(visit.original, incoming.original)
        XCTAssertNotNil(try store.reusableScreenText(id: saved.id))
        try store.delete(saved.id)
        XCTAssertNil(try store.reusableScreenText(id: saved.id))
        incoming.id = UUID(); incoming.screenshotFingerprint = "changed"
        XCTAssertNil(try store.saveScreenshot(incoming, jpeg: Data([2]), reusedOCRSource: saved.id))
        _ = try store.pruneImages(days: 30, maxBytes: 0)
        XCTAssertNil(try store.reusableScreenText(id: visit.id))
        XCTAssertEqual(try store.records().count, 1)
    }
    private func fixture(changed: Bool = false, width: Int = 3200, height: Int = 2048) -> CGImage {
        let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4, space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        context.setFillColor(NSColor.white.cgColor); context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        NSGraphicsContext.saveGraphicsState(); NSGraphicsContext.current = NSGraphicsContext(cgContext: context, flipped: false)
        for index in 0..<30 {
            let content = "项目记录 \(index) LinkAll OCR sample ABC 20261004"
            (content as NSString).draw(at: CGPoint(x: 80, y: height - 100 - index * 55), withAttributes: [.font: NSFont.systemFont(ofSize: 24), .foregroundColor: NSColor.black])
        }
        ((changed ? "UPDATE 56789" : "STATUS 12345") as NSString).draw(at: CGPoint(x: 80, y: 100), withAttributes: [.font: NSFont.systemFont(ofSize: 24), .foregroundColor: NSColor.black])
        NSGraphicsContext.restoreGraphicsState()
        return context.makeImage()!
    }
    func testRealVisionIncrementalRegionsAndBoundaryCoordinates() throws {
        let image = fixture(), first = ScreenOCR.recognize(image)
        XCTAssertTrue(first.ocrComplete)
        XCTAssertTrue(first.text.contains("12345"))
        XCTAssertEqual(first.regions.count, 2)
        XCTAssertTrue(first.ocrBlocks.allSatisfy { $0.bounds.y >= 0 && $0.bounds.y + $0.bounds.height <= 1 && $0.confidence != nil })
        let unchanged = ScreenOCR.recognize(image, previous: first)
        XCTAssertEqual(unchanged.recognizedRegions, 0); XCTAssertEqual(unchanged.reusedRegions, 2)
        let updated = ScreenOCR.recognize(fixture(changed: true), previous: first)
        XCTAssertEqual(updated.recognizedRegions, 1); XCTAssertEqual(updated.reusedRegions, 1)
        XCTAssertTrue(updated.text.contains("56789")); XCTAssertFalse(updated.text.contains("12345"))
        // Overlap must neither lose nor duplicate lines straddling a band boundary.
        XCTAssertEqual(first.ocrBlocks.filter { $0.text.contains("20261004") }.count, 30)
        let fresh = ScreenOCR.recognize(fixture(changed: true))
        XCTAssertEqual(updated.ocrBlocks, fresh.ocrBlocks)
        var incompatible = first; incompatible.version = 0
        XCTAssertEqual(ScreenOCR.recognize(image, previous: incompatible).reusedRegions, 0)
        print("SCREEN_OCR_FIXTURE full_ms=\(first.ocrMilliseconds) warm_full_ms=\(fresh.ocrMilliseconds) incremental_ms=\(updated.ocrMilliseconds) unchanged_ms=\(unchanged.ocrMilliseconds) recognized=\(updated.recognizedRegions)/\(updated.regions.count)")
    }
    func testVisibleAccessibilityWhenRequested() async throws {
        guard let target = ProcessInfo.processInfo.environment["LINKALL_AX_PROBE_PID"], let pid = Int32(target) else { throw XCTSkip("Set LINKALL_AX_PROBE_PID for a visible-window AX check") }
        let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
        let window = try XCTUnwrap(content.windows.first { $0.owningApplication?.processID == pid && $0.windowLayer == 0 })
        let display = try XCTUnwrap(content.displays.max { a, b in
            let ra = a.frame.intersection(window.frame), rb = b.frame.intersection(window.frame)
            return (ra.isNull ? 0 : ra.width * ra.height) < (rb.isNull ? 0 : rb.width * rb.height)
        })
        let start = ProcessInfo.processInfo.systemUptime
        let result = VisibleAccessibility.read(pid: pid, windowID: window.windowID, windowFrame: window.frame, displayFrame: display.frame)
        let hasMarker = result.blocks.contains { $0.text.contains("20261004") }
        let hasHiddenMarker = result.blocks.contains { $0.text.contains("TEST-0060") }
        print("SCREEN_AX_PROBE blocks=\(result.blocks.count) status=\(result.status) ms=\((ProcessInfo.processInfo.systemUptime - start) * 1000) visible_marker=\(hasMarker) hidden_marker=\(hasHiddenMarker)")
        XCTAssertTrue(hasMarker); XCTAssertFalse(hasHiddenMarker)
        if let expectedPath = ProcessInfo.processInfo.environment["LINKALL_OCR_EXPECTED_LINES"] {
            let lines = try JSONDecoder().decode([String].self, from: Data(contentsOf: URL(fileURLWithPath: expectedPath)))
            let joined = result.blocks.map(\.text).joined().filter { !$0.isWhitespace }
            let exact = lines.filter { joined.contains($0.filter { !$0.isWhitespace }) }.count
            print("SCREEN_AX_QUALITY exact_lines=\(exact)/\(lines.count)")
            XCTAssertEqual(exact, lines.count)
        }
    }
    /// Opt-in real-image comparison. Never prints image text or writes it to diagnostic logs.
    func testImageBenchmarkWhenRequested() throws {
        guard let path = ProcessInfo.processInfo.environment["LINKALL_OCR_BENCHMARK_IMAGE"] else { throw XCTSkip("Set LINKALL_OCR_BENCHMARK_IMAGE for an image benchmark") }
        let image = try XCTUnwrap(NSImage(contentsOfFile: path)?.cgImage(forProposedRect: nil, context: nil, hints: nil))
        let scale = min(1, 2200 / Double(max(image.width, image.height)))
        let context = try XCTUnwrap(CGContext(data: nil, width: Int(Double(image.width) * scale), height: Int(Double(image.height) * scale), bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        context.draw(image, in: CGRect(x: 0, y: 0, width: context.width, height: context.height))
        let oldImage = try XCTUnwrap(context.makeImage())
        var oldTimes: [Double] = [], newTimes: [Double] = [], reuseTimes: [Double] = []
        var oldCount = 0, newCount = 0
        var oldText = "", newText = ""
        var nativeWholeText = "", nativeWholeTimes: [Double] = []
        for _ in 0..<3 {
            let request = VNRecognizeTextRequest(); request.recognitionLevel = .accurate; request.recognitionLanguages = ["zh-Hans", "en-US"]; request.usesLanguageCorrection = false
            let start = ProcessInfo.processInfo.systemUptime
            try VNImageRequestHandler(cgImage: oldImage).perform([request])
            oldTimes.append((ProcessInfo.processInfo.systemUptime - start) * 1000)
            oldText = (request.results ?? []).compactMap { $0.topCandidates(1).first?.string }.joined(separator: "\n")
            oldCount = oldText.count
            let full = ScreenOCR.recognize(image), reused = ScreenOCR.recognize(image, previous: full)
            newTimes.append(full.ocrMilliseconds); reuseTimes.append(reused.ocrMilliseconds); newCount = full.text.count; newText = full.text
            XCTAssertTrue(full.ocrComplete)
            let wholeRequest = VNRecognizeTextRequest(); wholeRequest.recognitionLevel = .accurate; wholeRequest.recognitionLanguages = ["zh-Hans", "en-US"]; wholeRequest.usesLanguageCorrection = false
            let wholeStart = ProcessInfo.processInfo.systemUptime
            try VNImageRequestHandler(cgImage: image).perform([wholeRequest])
            nativeWholeTimes.append((ProcessInfo.processInfo.systemUptime - wholeStart) * 1000)
            nativeWholeText = (wholeRequest.results ?? []).compactMap { $0.topCandidates(1).first?.string }.joined(separator: "\n")
        }
        var result: [String: Any] = ["imageWidth": image.width, "imageHeight": image.height, "baselineMilliseconds": oldTimes, "nativeBandsMilliseconds": newTimes, "reusedBandsMilliseconds": reuseTimes, "baselineCharacterCount": oldCount, "nativeCharacterCount": newCount]
        if let expectedPath = ProcessInfo.processInfo.environment["LINKALL_OCR_EXPECTED_LINES"] {
            let lines = try JSONDecoder().decode([String].self, from: Data(contentsOf: URL(fileURLWithPath: expectedPath)))
            let normalize: (String) -> String = { $0.filter { !$0.isWhitespace } }
            result["expectedLines"] = lines.count
            result["baselineExactLines"] = lines.filter { normalize(oldText).contains(normalize($0)) }.count
            result["nativeExactLines"] = lines.filter { normalize(newText).contains(normalize($0)) }.count
            result["nativeWholeExactLines"] = lines.filter { normalize(nativeWholeText).contains(normalize($0)) }.count
            result["nativeWholeMilliseconds"] = nativeWholeTimes
        }
        let data = try JSONSerialization.data(withJSONObject: result, options: [.sortedKeys])
        print("SCREEN_OCR_BENCHMARK " + String(decoding: data, as: UTF8.self))
    }
}
