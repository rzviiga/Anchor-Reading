import Foundation
import CoreGraphics
import Vision

public struct AccentPatch {
    public let pixelRect: CGRect
    public let image: CGImage
    public var word: String = ""
    public var prefix: String = ""
    public var prefixRect: CGRect = .zero
    public var fontName: String = ""
    public var fitScore: Double = 0
}
public struct RecognitionResult {
    public let patches: [AccentPatch]
    public let wordCount: Int
    public let ocrMilliseconds: Double
    public let maskMilliseconds: Double
    public var totalMilliseconds: Double { ocrMilliseconds + maskMilliseconds }
    public func excludingPatches(intersecting regions: [CGRect]) -> RecognitionResult {
        RecognitionResult(patches: patches.filter { patch in !regions.contains { $0.intersects(patch.pixelRect) } },
                          wordCount: wordCount, ocrMilliseconds: ocrMilliseconds, maskMilliseconds: maskMilliseconds)
    }
}

public final class EnhancementEngine {
    private let renderer = NativeWordRenderer()
    private let words = try! NSRegularExpression(pattern: #"[\p{L}\p{M}]+(?:['’][\p{L}\p{M}]+)*"#)
    public init() {}
    public func recognize(_ frame: PixelFrame, policy: ReadingPolicy = .init()) throws -> RecognitionResult {
        guard let image = frame.image else { throw NSError(domain: "AnchorOverlay", code: 1, userInfo: [NSLocalizedDescriptionKey: "无法读取屏幕像素"]) }
        let started = ProcessInfo.processInfo.systemUptime
        let request = VNRecognizeTextRequest()
        request.recognitionLevel = .accurate // Use reliable whole words, never partial-character boxes.
        request.recognitionLanguages = ["en-US"]
        request.usesLanguageCorrection = false
        // A fixed fraction excluded small UI text on tall/high-resolution displays.
        request.minimumTextHeight = Float(6.0 / Double(frame.height))
        try VNImageRequestHandler(cgImage: image, orientation: .up).perform([request])
        let recognized = ProcessInfo.processInfo.systemUptime
        var patches = [AccentPatch](); patches.reserveCapacity(300)
        var count = 0
        for (lineIndex, observation) in (request.results ?? []).enumerated() {
            // Vision confidence applies to a whole line. Individual words still
            // have to pass the source-pixel check before we draw anything.
            guard let candidate = observation.topCandidates(1).first, candidate.confidence >= 0.2 else { continue }
            let text = candidate.string
            // Longer words provide better font evidence for short words on this line.
            let matches = words.matches(in: text, range: NSRange(text.startIndex..., in: text))
                .sorted { $0.range.length == $1.range.length ? $0.range.location < $1.range.location : $0.range.length > $1.range.length }
            for match in matches {
                guard let range = Range(match.range, in: text),
                      let prefixRange = policy.prefixes(in: String(text[range])).first,
                      let box = try? candidate.boundingBox(for: range) else { continue }
                // Rotated/skewed text is not safe for an axis-aligned pixel overlay.
                guard abs(box.topLeft.y - box.topRight.y) * Double(frame.height) < 3 else { continue }
                let rect = OverlayGeometry.pixels(from: box.boundingBox, width: frame.width, height: frame.height)
                guard rect.height >= 7, rect.height <= 160, rect.width >= 2 else { continue }
                count += 1
                let word = String(text[range])
                let prefixCount = word[prefixRange].count
                if let patch = renderer.make(frame: frame, word: word, prefixCount: prefixCount, wordRect: rect, lineKey: "\(lineIndex):\(text)") { patches.append(patch) }
                if patches.count >= 1800 { break }
            }
            if patches.count >= 1800 { break }
        }
        return RecognitionResult(patches: patches, wordCount: count, ocrMilliseconds: (recognized-started)*1000,
                                 maskMilliseconds: (ProcessInfo.processInfo.systemUptime-recognized)*1000)
    }
}

public enum StrokeMask {
    /// Extract foreground strokes against a near-uniform background, then add a thin
    /// alpha fringe. The original pixels stay visible; no replacement text is drawn.
    public static func make(frame: PixelFrame, rect: CGRect, strength: Double) -> AccentPatch? {
        let pad = 2
        let x0 = max(0, Int(floor(rect.minX)) - pad), y0 = max(0, Int(floor(rect.minY)) - pad)
        let x1 = min(frame.width, Int(ceil(rect.maxX)) + pad), y1 = min(frame.height, Int(ceil(rect.maxY)) + pad)
        let w = x1-x0, h = y1-y0
        guard w > 4, h > 4, w*h < 150_000 else { return nil }
        return frame.bytes.withUnsafeBytes { raw in
            let source = raw.baseAddress!.assumingMemoryBound(to: UInt8.self)
            func rgb(_ x: Int, _ y: Int) -> (Double, Double, Double) {
                let i = (y0+y)*frame.stride+(x0+x)*4
                return (Double(source[i+2]), Double(source[i+1]), Double(source[i]))
            }
            func distance(_ a: (Double,Double,Double), _ b: (Double,Double,Double)) -> Double {
                max(abs(a.0-b.0), max(abs(a.1-b.1), abs(a.2-b.2)))
            }
            var borders = [(Double,Double,Double)]()
            for x in stride(from: 0, to: w, by: max(1,w/20)) { borders += [rgb(x,0),rgb(x,h-1)] }
            for y in stride(from: 0, to: h, by: max(1,h/12)) { borders += [rgb(0,y),rgb(w-1,y)] }
            func median(_ v: [Double]) -> Double { v.sorted()[v.count/2] }
            let bg = (median(borders.map{$0.0}),median(borders.map{$0.1}),median(borders.map{$0.2}))
            guard Double(borders.filter{distance($0,bg)>30}.count)/Double(borders.count) < 0.28 else { return nil }
            let innerX0=max(1,Int(floor(rect.minX))-x0), innerX1=min(w-1,Int(ceil(rect.maxX))-x0)
            let innerY0=max(1,Int(floor(rect.minY))-y0), innerY1=min(h-1,Int(ceil(rect.maxY))-y0)
            guard innerX1>innerX0, innerY1>innerY0 else { return nil }
            var candidates = [(Double,Double,Double)]()
            for y in innerY0..<innerY1 { for x in innerX0..<innerX1 {
                let value = rgb(x,y)
                if distance(value,bg)>55 { candidates.append(value) }
            }}
            guard candidates.count >= 4, candidates.count < w*h*3/5 else { return nil }
            candidates.sort{distance($0,bg)>distance($1,bg)}
            let darkest = Array(candidates.prefix(max(3,candidates.count/3)))
            let fg = (median(darkest.map{$0.0}),median(darkest.map{$0.1}),median(darkest.map{$0.2}))
            let contrast = distance(fg,bg)
            guard contrast>55 else { return nil }
            var mask=[Float](repeating:0,count:w*h)
            for y in innerY0..<innerY1 { for x in innerX0..<innerX1 {
                let point = rgb(x,y)
                let coverage = min(1,max(0,distance(point,bg)/contrast))
                let expected = (bg.0+(fg.0-bg.0)*coverage,bg.1+(fg.1-bg.1)*coverage,bg.2+(fg.2-bg.2)*coverage)
                if distance(point,expected)<35 { mask[y*w+x]=Float(coverage) }
            }}
            var output=[UInt8](repeating:0,count:w*h*4)
            var painted=0
            for y in 1..<(h-1) { for x in 1..<(w-1) {
                let index=y*w+x
                // A small cross dilation thickens a stroke without filling diagonal corners.
                let expanded=max(mask[index],max(mask[index-1],max(mask[index+1],max(mask[index-w],mask[index+w]))))
                let alpha = min(0.88,Double(max(0,expanded-mask[index]))*strength)
                if alpha<0.035 { continue }
                let i=index*4
                output[i]=UInt8(fg.0*alpha); output[i+1]=UInt8(fg.1*alpha); output[i+2]=UInt8(fg.2*alpha); output[i+3]=UInt8(alpha*255)
                painted+=1
            }}
            guard painted>2, let provider=CGDataProvider(data: Data(output) as CFData),
                  let image=CGImage(width:w,height:h,bitsPerComponent:8,bitsPerPixel:32,bytesPerRow:w*4,
                                    space:CGColorSpaceCreateDeviceRGB(),bitmapInfo:CGBitmapInfo(rawValue:CGImageAlphaInfo.premultipliedLast.rawValue),
                                    provider:provider,decode:nil,shouldInterpolate:true,intent:.defaultIntent) else { return nil }
            return AccentPatch(pixelRect:CGRect(x:x0,y:y0,width:w,height:h),image:image)
        }
    }
}
