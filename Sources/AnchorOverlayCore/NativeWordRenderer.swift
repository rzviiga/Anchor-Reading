import Foundation
import CoreGraphics
import CoreText

/// A patch is emitted only after a complete OCR word fits the actual source ink.
/// Vision's partial-character boxes are deliberately never used for positioning.
public final class NativeWordRenderer {
    private struct CacheKey: Hashable { let word:String; let count:Int; let width:Int; let height:Int; let pixels:Int }
    private enum Cached { case skipped(String?); case patch(AccentPatch) }
    private var cache=[CacheKey:Cached]()
    private struct Face {
        let name: String
        let regular: CTFont
        let bold: CTFont
    }
    private struct Fit {
        let face: Face
        let line: CTLine
        let ink: CGRect
        let sx: Double
        let sy: Double
        let tx: Double
        let ty: Double
        let score: Double
    }
    private let faces: [Face]
    private let recoveryFaces: [Face]
    private var preferred: [String: String] = [:]
    public init() {
        var fonts = [CTFontCreateUIFontForLanguage(.system, 32, nil)!]
        fonts += ["Helvetica", "ArialMT", "Georgia", "TimesNewRomanPSMT", "Menlo-Regular", "Verdana", "TrebuchetMS", "AvenirNext-Regular"].map {
            CTFontCreateWithName($0 as CFString, 32, nil)
        }
        var names = Set<String>()
        func face(_ font: CTFont) -> Face? {
            let name = CTFontCopyPostScriptName(font) as String
            guard names.insert(name).inserted,
                  let bold = CTFontCreateCopyWithSymbolicTraits(font, 32, nil, .boldTrait, .boldTrait) else { return nil }
            return Face(name: name, regular: font, bold: bold)
        }
        faces = fonts.compactMap(face)
        // Only use installed fonts; a missing web font must not silently resolve
        // to LastResort. These are tried only when the original matcher fails.
        let available = Set(CTFontManagerCopyAvailablePostScriptNames() as! [String])
        let extra = ["HelveticaNeue", "HelveticaNeue-Medium", "ArialUnicodeMS", "ArialRoundedMTBold",
                     "SFProText-Regular", "SFProDisplay-Regular", "SFUIText-Regular", "SFUIDisplay-Regular",
                     "Inter-Regular", "Inter", "Roboto-Regular", "Roboto", "SegoeUI", "OpenSans-Regular",
                     "NotoSans-Regular", "Lato-Regular", "Montserrat-Regular", "Aptos", "Calibri",
                     "CourierNewPSMT", "Courier", "Palatino-Roman", "Baskerville", "LucidaGrande"]
        recoveryFaces = extra.filter { available.contains($0) }.compactMap {
            face(CTFontCreateWithName($0 as CFString, 32, nil))
        }
    }
    private func line(_ text: String, font: CTFont) -> CTLine {
        CTLineCreateWithAttributedString(NSAttributedString(string: text, attributes: [
            NSAttributedString.Key(kCTFontAttributeName as String): font,
            NSAttributedString.Key(kCTForegroundColorAttributeName as String): CGColor(gray: 1, alpha: 1),
            NSAttributedString.Key(kCTLigatureAttributeName as String): 0
        ]))
    }
    public func make(frame: PixelFrame, word: String, prefixCount: Int, wordRect: CGRect, lineKey: String) -> AccentPatch? {
        let box=wordRect.insetBy(dx:-2,dy:-2).integral.intersection(CGRect(x:0,y:0,width:frame.width,height:frame.height))
        guard !box.isNull, let digest=frame.regionHash(box) else { return nil }
        let key=CacheKey(word:word,count:prefixCount,width:Int(box.width),height:Int(box.height),pixels:digest)
        if let cached=cache[key] {
            switch cached {
            case .skipped(let font):
                // A later word may teach us the line's font; don't freeze an
                // earlier failure after that new evidence becomes available.
                if font == preferred[lineKey] { return nil }
            case .patch(let patch):
                if word.count >= 5 { remember(patch.fontName, for: lineKey) }
                return AccentPatch(pixelRect:box,image:patch.image,word:patch.word,prefix:patch.prefix,
                    prefixRect:patch.prefixRect.offsetBy(dx:box.minX-patch.pixelRect.minX,dy:box.minY-patch.pixelRect.minY),fontName:patch.fontName,fitScore:patch.fitScore)
            }
        }
        let patch=render(frame:frame,word:word,prefixCount:prefixCount,wordRect:wordRect,lineKey:lineKey)
        if cache.count>=1024 { cache.removeAll(keepingCapacity:true) }
        cache[key]=patch.map(Cached.patch) ?? .skipped(preferred[lineKey])
        return patch
    }
    private func remember(_ font: String, for lineKey: String) {
        if preferred.count > 128 { preferred.removeAll(keepingCapacity: true) }
        preferred[lineKey] = font
    }
    private func render(frame: PixelFrame, word: String, prefixCount: Int, wordRect: CGRect, lineKey: String) -> AccentPatch? {
        guard !word.isEmpty, prefixCount > 0, prefixCount <= word.count,
              let sample = InkSample(frame: frame, rect: wordRect)
                ?? InkSample(frame: frame, rect: wordRect, recoverLowContrast: true) else { return nil }
        let w = sample.width, h = sample.height
        let target = sample.inkRect
        let known = recoveryFaces.filter { $0.name == preferred[lineKey] }
        let ordered = (faces + known).sorted { ($0.name == preferred[lineKey] ? 0 : 1) < ($1.name == preferred[lineKey] ? 0 : 1) }
        guard let context = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w,
                                      space: CGColorSpaceCreateDeviceGray(), bitmapInfo: CGImageAlphaInfo.none.rawValue) else { return nil }
        context.setShouldAntialias(true); context.setShouldSmoothFonts(false)
        func evaluate(_ face: Face, _ regular: CTLine, _ ink: CGRect,
                      _ sx: Double, _ sy: Double, _ tx: Double, _ ty: Double) -> Fit {
            // Reuse one small buffer throughout the search, off the drawing thread.
            memset(context.data!, 0, w*h)
            context.saveGState()
            context.translateBy(x: tx, y: ty); context.scaleBy(x: sx, y: sy)
            context.textPosition = .zero
            CTLineDraw(regular, context)
            context.restoreGState()
            let pixels = context.data!.assumingMemoryBound(to: UInt8.self)
            var intersection = 0.0, total = 0.0
            for i in 0..<(w*h) {
                let a = sample.coverage[i], b = Double(pixels[i]) / 255
                intersection += min(a, b); total += a + b
            }
            return Fit(face: face, line: regular, ink: ink, sx: sx, sy: sy, tx: tx, ty: ty,
                       score: total > 0 ? 2 * intersection / total : 0)
        }
        var best: Fit?
        var seeds = [Fit]()
        func initialFit(_ face: Face) -> Fit? {
            let regular = line(word, font: face.regular)
            let ink = CTLineGetBoundsWithOptions(regular, [.useGlyphPathBounds])
            guard ink.width > 0, ink.height > 0 else { return nil }
            let sx = target.width / ink.width, sy = target.height / ink.height
            // Reject font shapes that require severe distortion just to fit the OCR box.
            guard sx / sy > 0.82, sx / sy < 1.18 else { return nil }
            let tx = target.minX - ink.minX * sx
            let ty = Double(h) - target.maxY - ink.minY * sy
            return evaluate(face, regular, ink, sx, sy, tx, ty)
        }
        for face in ordered {
            guard let fit = initialFit(face) else { continue }
            seeds.append(fit)
            if fit.score > (best?.score ?? 0) { best = fit }
            if fit.score >= 0.91 { break }
            if face.name == preferred[lineKey] && fit.score >= 0.83 { break }
        }
        let threshold = word.count < 3 ? 0.82 : 0.78
        if (best?.score ?? 0) < threshold {
            for face in recoveryFaces where face.name != preferred[lineKey] {
                guard let fit = initialFit(face) else { continue }
                seeds.append(fit)
                if fit.score > (best?.score ?? 0) { best = fit }
                if fit.score >= 0.91 { break }
            }
        }
        if (best?.score ?? 0) < threshold {
            // OCR and antialiasing round ink edges differently. Refine only the
            // two most plausible shapes, keeping the existing acceptance scores.
            for seed in seeds.sorted(by: { $0.score > $1.score }).prefix(2) where seed.score >= 0.55 {
                var refined = seed
                for step in [0.5, 0.25] {
                    for axis in 0..<4 {
                        let base = refined
                        for sign in [-1.0, 1.0] {
                            let delta = sign * step
                            var sx = base.sx, sy = base.sy, tx = base.tx, ty = base.ty
                            switch axis {
                            case 0: tx += delta
                            case 1: ty += delta
                            case 2:
                                sx += delta / base.ink.width
                                tx -= base.ink.midX * (sx - base.sx)
                            default:
                                sy += delta / base.ink.height
                                ty -= base.ink.midY * (sy - base.sy)
                            }
                            guard sx > 0, sy > 0, sx / sy > 0.82, sx / sy < 1.18 else { continue }
                            let fit = evaluate(base.face, base.line, base.ink, sx, sy, tx, ty)
                            if fit.score > refined.score { refined = fit }
                        }
                    }
                }
                if refined.score > (best?.score ?? 0) { best = refined }
                if refined.score >= threshold { break }
            }
        }
        // Tiny words have little font-identification information: require a stronger fit.
        guard let fit = best, fit.score >= threshold else { return nil }
        if word.count >= 5 { remember(fit.face.name, for: lineKey) }
        let prefix = String(word.prefix(prefixCount))
        let regularPrefix = line(prefix, font: fit.face.regular)
        let boldPrefix = line(prefix, font: fit.face.bold)
        let index = prefix.utf16.count
        let advance = CTLineGetOffsetForStringIndex(fit.line, index, nil)
        let boldAdvance = CTLineGetTypographicBounds(boldPrefix, nil, nil, nil)
        guard advance > 0, boldAdvance > 0 else { return nil }
        let boundary = fit.tx + advance * fit.sx
        let prefixInk = CTLineGetBoundsWithOptions(regularPrefix, [.useGlyphPathBounds])
        // Native bold occupies the original prefix's advance. The suffix is copied
        // byte-for-byte from the source, never retyped from OCR.
        let end = prefixCount == word.count ? Double(w) : min(Double(w), floor(boundary))
        let begin = max(0, floor(fit.tx + prefixInk.minX * fit.sx - 1))
        guard end > begin else { return nil }
        let output = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w*4,
                               space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        // Opaque original pixels + solid native glyphs. No translucent dilation fringe.
        output.draw(sample.image, in: CGRect(x: 0, y: 0, width: w, height: h))
        output.saveGState()
        output.clip(to: CGRect(x: begin, y: 0, width: end-begin, height: Double(h)))
        output.setFillColor(sample.background)
        output.fill(CGRect(x: begin, y: 0, width: end-begin, height: Double(h)))
        output.translateBy(x: fit.tx, y: fit.ty)
        output.scaleBy(x: fit.sx * advance / boldAdvance, y: fit.sy)
        let foregroundLine = CTLineCreateWithAttributedString(NSAttributedString(string: prefix, attributes: [
            NSAttributedString.Key(kCTFontAttributeName as String): fit.face.bold,
            NSAttributedString.Key(kCTForegroundColorAttributeName as String): sample.foreground,
            NSAttributedString.Key(kCTLigatureAttributeName as String): 0
        ]))
        output.setShouldAntialias(true); output.setShouldSmoothFonts(false)
        output.textPosition = .zero; CTLineDraw(foregroundLine, output)
        output.restoreGState()
        guard let image = output.makeImage() else { return nil }
        return AccentPatch(pixelRect: sample.rect, image: image, word: word, prefix: prefix,
                           prefixRect: CGRect(x: sample.rect.minX+begin, y: sample.rect.minY, width: end-begin, height: Double(h)),
                           fontName: fit.face.name, fitScore: fit.score)
    }
}

private struct InkSample {
    let rect: CGRect
    let width: Int
    let height: Int
    let inkRect: CGRect
    let coverage: [Double]
    let background: CGColor
    let foreground: CGColor
    let image: CGImage
    init?(frame: PixelFrame, rect requested: CGRect, recoverLowContrast: Bool = false) {
        let box = requested.insetBy(dx: -2, dy: -2).integral.intersection(CGRect(x: 0, y: 0, width: frame.width, height: frame.height))
        guard !box.isNull, box.width >= 5, box.height >= 7, box.width*box.height < 180_000 else { return nil }
        let x0=Int(box.minX), y0=Int(box.minY), w=Int(box.width), h=Int(box.height)
        var rgb = [SIMD3<Double>](); rgb.reserveCapacity(w*h)
        frame.bytes.withUnsafeBytes { raw in
            let p=raw.baseAddress!.assumingMemoryBound(to: UInt8.self)
            for y in 0..<h { for x in 0..<w {
                let i=(y+y0)*frame.stride+(x+x0)*4
                rgb.append(SIMD3(Double(p[i+2]),Double(p[i+1]),Double(p[i])))
            }}
        }
        func dist(_ a: SIMD3<Double>, _ b: SIMD3<Double>) -> Double { let d=a-b; return max(abs(d.x),max(abs(d.y),abs(d.z))) }
        func median(_ values: [SIMD3<Double>]) -> SIMD3<Double> {
            let n=values.count/2
            return SIMD3(values.map{$0.x}.sorted()[n],values.map{$0.y}.sorted()[n],values.map{$0.z}.sorted()[n])
        }
        var border=[SIMD3<Double>]()
        for x in 0..<w { border.append(rgb[x]); border.append(rgb[(h-1)*w+x]) }
        for y in 1..<(h-1) { border.append(rgb[y*w]); border.append(rgb[y*w+w-1]) }
        let bg=median(border)
        guard Double(border.filter{dist($0,bg)>25}.count)/Double(border.count)<0.16 else { return nil }
        let contrasted=rgb.filter{dist($0,bg) > (recoverLowContrast ? 35 : 60)}.sorted{dist($0,bg)>dist($1,bg)}
        guard contrasted.count >= 5 else { return nil }
        let fg=median(Array(contrasted.prefix(max(3,contrasted.count/3))))
        let delta=fg-bg, denominator=delta.x*delta.x+delta.y*delta.y+delta.z*delta.z
        guard denominator > (recoverLowContrast ? 1800 : 5000) else { return nil }
        var coverage=[Double](repeating:0,count:w*h)
        var minX=w, minY=h, maxX=0, maxY=0, alien=0
        for i in rgb.indices {
            let d=rgb[i]-bg
            let alpha=max(0,min(1,(d.x*delta.x+d.y*delta.y+d.z*delta.z)/denominator))
            if dist(rgb[i],bg+delta*alpha)>24 { alien+=1; continue }
            coverage[i]=alpha
            if alpha>0.18 { minX=min(minX,i%w);maxX=max(maxX,i%w);minY=min(minY,i/w);maxY=max(maxY,i/w) }
        }
        guard maxX>minX, maxY>minY, Double(alien)/Double(w*h)<0.03 else { return nil }
        // Pixel-tight bounds prevent an OCR box's empty margins from shifting the word.
        self.rect=box; width=w; height=h
        // Match outline edges to the centers of the first/last covered pixels.
        // Treating the inclusive pixel count as an outline width enlarged every
        // template by about one pixel, particularly harmful at small text sizes.
        inkRect=CGRect(x:Double(minX)+0.5,y:Double(minY)+0.5,width:Double(maxX-minX),height:Double(maxY-minY))
        self.coverage=coverage
        // Use the same color space as the captured bytes; implicit sRGB conversion
        // otherwise creates visibly lighter rectangles on dark backgrounds.
        let space=CGColorSpaceCreateDeviceRGB()
        background=CGColor(colorSpace:space,components:[bg.x/255,bg.y/255,bg.z/255,1])!
        foreground=CGColor(colorSpace:space,components:[fg.x/255,fg.y/255,fg.z/255,1])!
        var pixels=[UInt8](); pixels.reserveCapacity(w*h*4)
        for color in rgb { pixels += [UInt8(color.x),UInt8(color.y),UInt8(color.z),255] }
        guard let provider=CGDataProvider(data:Data(pixels) as CFData), let image=CGImage(width:w,height:h,bitsPerComponent:8,bitsPerPixel:32,bytesPerRow:w*4,
            space:CGColorSpaceCreateDeviceRGB(),bitmapInfo:CGBitmapInfo(rawValue:CGImageAlphaInfo.premultipliedLast.rawValue),provider:provider,decode:nil,shouldInterpolate:false,intent:.defaultIntent) else { return nil }
        self.image=image
    }
}
