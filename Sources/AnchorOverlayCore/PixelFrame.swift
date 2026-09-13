import Foundation
import CoreGraphics
import CoreVideo

public struct FrameSignature: Equatable {
    public let samples: [UInt8]
    public func differs(from other: FrameSignature) -> Bool {
        guard samples.count == other.samples.count else { return true }
        var changed = 0
        for (a, b) in zip(samples, other.samples) where abs(Int(a) - Int(b)) > 12 {
            changed += 1
            if changed >= 3 { return true }
        }
        return false
    }
    public static func read(_ buffer: CVPixelBuffer) -> FrameSignature? {
        guard CVPixelBufferGetPixelFormatType(buffer) == kCVPixelFormatType_32BGRA else { return nil }
        CVPixelBufferLockBaseAddress(buffer, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(buffer, .readOnly) }
        guard let address = CVPixelBufferGetBaseAddress(buffer) else { return nil }
        let p = address.assumingMemoryBound(to: UInt8.self)
        return sample(p, width: CVPixelBufferGetWidth(buffer), height: CVPixelBufferGetHeight(buffer), stride: CVPixelBufferGetBytesPerRow(buffer))
    }
    static func sample(_ p: UnsafePointer<UInt8>, width: Int, height: Int, stride: Int) -> FrameSignature {
        let columns = min(320, width), rows = min(200, height)
        var output = [UInt8](); output.reserveCapacity(columns * rows)
        for row in 0..<rows {
            let y = min(height - 1, (row * height + height / 2) / rows)
            for column in 0..<columns {
                let x = min(width - 1, (column * width + width / 2) / columns)
                let i = y * stride + x * 4
                output.append(UInt8((Int(p[i]) * 19 + Int(p[i+1]) * 183 + Int(p[i+2]) * 54) >> 8))
            }
        }
        return FrameSignature(samples: output)
    }
}

public struct PixelFrame {
    public let bytes: Data
    public let width: Int
    public let height: Int
    public let stride: Int
    public init?(buffer: CVPixelBuffer) {
        guard CVPixelBufferGetPixelFormatType(buffer) == kCVPixelFormatType_32BGRA else { return nil }
        CVPixelBufferLockBaseAddress(buffer, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(buffer, .readOnly) }
        guard let p = CVPixelBufferGetBaseAddress(buffer) else { return nil }
        width = CVPixelBufferGetWidth(buffer); height = CVPixelBufferGetHeight(buffer)
        stride = CVPixelBufferGetBytesPerRow(buffer)
        bytes = Data(bytes: p, count: stride * height)
    }
    public init(bytes: Data, width: Int, height: Int, stride: Int) {
        precondition(width > 0 && height > 0 && stride >= width * 4 && bytes.count >= stride * height)
        self.bytes = bytes; self.width = width; self.height = height; self.stride = stride
    }
    public var image: CGImage? {
        guard let provider = CGDataProvider(data: bytes as CFData) else { return nil }
        return CGImage(width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: stride,
                       space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: [.byteOrder32Little, CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedFirst.rawValue)],
                       provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent)
    }
    public var signature: FrameSignature {
        bytes.withUnsafeBytes { FrameSignature.sample($0.baseAddress!.assumingMemoryBound(to: UInt8.self), width: width, height: height, stride: stride) }
    }
    public func regionHash(_ rect: CGRect) -> Int? {
        let x=Int(rect.minX),y=Int(rect.minY),w=Int(rect.width),h=Int(rect.height)
        guard x>=0,y>=0,w>0,h>0,x+w<=width,y+h<=height else { return nil }
        return bytes.withUnsafeBytes { raw in
            var hasher=Hasher()
            for row in y..<(y+h) {
                hasher.combine(bytes:UnsafeRawBufferPointer(start:raw.baseAddress!.advanced(by:row*stride+x*4),count:w*4))
            }
            return hasher.finalize()
        }
    }
    /// Compare the actual pixels covered by each patch, rather than dropping all
    /// text because an unrelated caret, clock, or animation changed elsewhere.
    public func unchangedPatchIndices(in buffer: CVPixelBuffer, rects: [CGRect]) -> [Int] {
        guard CVPixelBufferGetWidth(buffer)==width, CVPixelBufferGetHeight(buffer)==height,
              CVPixelBufferGetPixelFormatType(buffer)==kCVPixelFormatType_32BGRA else { return [] }
        CVPixelBufferLockBaseAddress(buffer,.readOnly)
        defer { CVPixelBufferUnlockBaseAddress(buffer,.readOnly) }
        guard let base=CVPixelBufferGetBaseAddress(buffer) else { return [] }
        let rowBytes=CVPixelBufferGetBytesPerRow(buffer)
        return bytes.withUnsafeBytes { raw in
            rects.indices.filter { index in
                let rect=rects[index].integral
                let x=Int(rect.minX),y=Int(rect.minY),w=Int(rect.width),h=Int(rect.height)
                guard x>=0,y>=0,x+w<=width,y+h<=height else { return false }
                for row in y..<(y+h) {
                    if memcmp(raw.baseAddress!.advanced(by:row*stride+x*4),base.advanced(by:row*rowBytes+x*4),w*4) != 0 { return false }
                }
                return true
            }
        }
    }
}
