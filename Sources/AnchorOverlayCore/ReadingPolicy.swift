import Foundation
import CoreGraphics

public struct ReadingPolicy: Sendable {
    public var ratio: Double
    public var maxLetters: Int
    public var strength: Double
    public init(ratio: Double = 0.4, maxLetters: Int = 4, strength: Double = 0.7) {
        self.ratio = max(0.05, min(1, ratio))
        self.maxLetters = max(1, min(8, maxLetters))
        self.strength = max(0.1, min(1, strength))
    }
    /// Unicode words are tokenized intact; only ASCII English is enhanced.
    public func prefixes(in text: String) -> [Range<String.Index>] {
        let pattern = #"[\p{L}\p{M}]+(?:['’][\p{L}\p{M}]+)*"#
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return [] }
        return regex.matches(in: text, range: NSRange(text.startIndex..., in: text)).compactMap { match in
            guard let range = Range(match.range, in: text) else { return nil }
            let word = text[range]
            guard word.unicodeScalars.allSatisfy({ scalar in
                (65...90).contains(scalar.value) || (97...122).contains(scalar.value) || scalar == "'" || scalar == "’"
            }) else { return nil }
            let stem = word.prefix { $0 != "'" && $0 != "’" }
            let count = min(maxLetters, Int(ceil(Double(stem.count) * ratio)))
            guard count > 0 else { return nil }
            return range.lowerBound..<text.index(range.lowerBound, offsetBy: count)
        }
    }
}

public struct FreshnessGate {
    public private(set) var revision: UInt64 = 0
    public private(set) var needsRecognition = true
    public private(set) var lastChange: TimeInterval = 0
    public private(set) var blockedUntil: TimeInterval = 0
    public private(set) var lastAttempt: TimeInterval = -.infinity
    public var settleInterval: TimeInterval = 0.10
    public var minimumOCRInterval: TimeInterval = 0.22
    public init() {}
    public mutating func changed(at time: TimeInterval) {
        revision &+= 1; lastChange = time; needsRecognition = true
    }
    /// A verification pass is not a screen change: keep the current presentation
    /// and accept an already-running request for this same revision.
    public mutating func requestRefresh() { needsRecognition = true }
    public mutating func interacted(at time: TimeInterval, cooldown: TimeInterval = 0.16) {
        changed(at: time); blockedUntil = max(blockedUntil, time + cooldown)
    }
    public func ready(at time: TimeInterval) -> Bool {
        needsRecognition && time >= blockedUntil && time - lastChange >= settleInterval && time - lastAttempt >= minimumOCRInterval
    }
    public mutating func begin(at time: TimeInterval) -> UInt64 {
        lastAttempt = time; return revision
    }
    public func accepts(_ token: UInt64, at time: TimeInterval) -> Bool {
        token == revision && time >= blockedUntil && time - lastChange >= settleInterval
    }
    public mutating func completed(_ token: UInt64, at time: TimeInterval) -> Bool {
        guard accepts(token, at: time) else { return false }
        needsRecognition = false; return true
    }
}

public enum OverlayGeometry {
    /// Vision is bottom-left normalized; capture pixels are top-left.
    public static func pixels(from normalized: CGRect, width: Int, height: Int) -> CGRect {
        CGRect(x: normalized.minX * Double(width), y: (1 - normalized.maxY) * Double(height),
               width: normalized.width * Double(width), height: normalized.height * Double(height))
    }
    public static func points(from pixels: CGRect, pixelWidth: Int, pixelHeight: Int, screenSize: CGSize) -> CGRect {
        CGRect(x: pixels.minX / Double(pixelWidth) * screenSize.width,
               y: pixels.minY / Double(pixelHeight) * screenSize.height,
               width: pixels.width / Double(pixelWidth) * screenSize.width,
               height: pixels.height / Double(pixelHeight) * screenSize.height)
    }
}
