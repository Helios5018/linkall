import Foundation

public enum PetSizing {
    public static let range: ClosedRange<Double> = 80...360
    public static let standard: Double = 150
    public static func clamped(_ size: Double) -> Double {
        size.isFinite ? min(range.upperBound, max(range.lowerBound, size)) : standard
    }
}
