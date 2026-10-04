import Foundation
import CryptoKit

/// Full-resolution, canonical RGBA pixels, before lossy JPEG encoding. Never hash OCR text.
public enum ScreenshotFingerprint {
    public static func make(width: Int, height: Int, rgba: Data) -> String {
        var hash = SHA256()
        hash.update(data: Data("rgba8-srgb-v1:\(width)x\(height):".utf8))
        hash.update(data: rgba)
        return hash.finalize().map { String(format: "%02x", $0) }.joined()
    }
}
