import Foundation
import CoreGraphics
import CoreText
import CoreVideo
import ImageIO
import UniformTypeIdentifiers
import Vision
import AnchorOverlayCore

let folder=URL(fileURLWithPath:CommandLine.arguments.count>1 ? CommandLine.arguments[1] : "qa/v0.2",isDirectory:true)
try FileManager.default.createDirectory(at:folder,withIntermediateDirectories:true)
func save(_ image:CGImage,_ name:String) {
    let writer=CGImageDestinationCreateWithURL(folder.appendingPathComponent(name) as CFURL,UTType.png.identifier as CFString,1,nil)!
    CGImageDestinationAddImage(writer,image,nil);precondition(CGImageDestinationFinalize(writer))
}
var checks=0
func check(_ condition:@autoclosure()->Bool,_ message:String) { precondition(condition(),message);checks+=1 }
struct Expected { let rect:CGRect;let prefixStart:Double;let prefixEnd:Double;let label:String }
let width=3200,height=1400
let c=CGContext(data:nil,width:width,height:height,bitsPerComponent:8,bytesPerRow:width*4,space:CGColorSpaceCreateDeviceRGB(),
    bitmapInfo:CGBitmapInfo.byteOrder32Little.rawValue|CGImageAlphaInfo.premultipliedFirst.rawValue)!
c.setFillColor(CGColor(gray:0.98,alpha:1));c.fill(CGRect(x:0,y:0,width:width,height:height))
c.setFillColor(CGColor(gray:0.10,alpha:1));c.fill(CGRect(x:1600,y:0,width:1600,height:height))
let sentence="Remove the dreamnia watermark in downloads."
let wmRange=sentence.range(of:"watermark")!
var expected=[Expected]()
for (fi,name) in ["Helvetica","Georgia",".AppleSystemUIFont"].enumerated() {
    for (si,size) in [14.0,18.0,24.0].enumerated() {
        for theme in 0..<2 {
            let font=name.hasPrefix(".") ? CTFontCreateUIFontForLanguage(.system,size*2,nil)! : CTFontCreateWithName(name as CFString,size*2,nil)
            let color=CGColor(gray:theme==0 ? 0.08 : 0.95,alpha:1)
            let line=CTLineCreateWithAttributedString(NSAttributedString(string:sentence,attributes:[
                NSAttributedString.Key(kCTFontAttributeName as String):font,
                NSAttributedString.Key(kCTForegroundColorAttributeName as String):color,
                NSAttributedString.Key(kCTLigatureAttributeName as String):0]))
            let x=Double(theme*1600+60),top=100.0+Double(fi*3+si)*140
            let baseline=Double(height)-top-size*2
            c.textPosition=CGPoint(x:x,y:baseline);CTLineDraw(line,c)
            let start=CTLineGetOffsetForStringIndex(line,wmRange.lowerBound.utf16Offset(in:sentence),nil)
            let end=CTLineGetOffsetForStringIndex(line,wmRange.upperBound.utf16Offset(in:sentence),nil)
            let pe=CTLineGetOffsetForStringIndex(line,sentence.index(wmRange.lowerBound,offsetBy:4).utf16Offset(in:sentence),nil)
            expected.append(Expected(rect:CGRect(x:x+start,y:top,width:end-start,height:size*2+4),prefixStart:x+start,prefixEnd:x+pe,label:"\(name) \(size)pt theme\(theme)"))
        }
    }
}
let frame=PixelFrame(bytes:Data(bytes:c.data!,count:width*height*4),width:width,height:height,stride:width*4)
save(frame.image!,"regression-original.png")
let result=try EnhancementEngine().recognize(frame)
let output=CGContext(data:nil,width:width,height:height,bitsPerComponent:8,bytesPerRow:width*4,space:CGColorSpaceCreateDeviceRGB(),bitmapInfo:CGImageAlphaInfo.premultipliedLast.rawValue)!
output.draw(frame.image!,in:CGRect(x:0,y:0,width:width,height:height))
var records=[[String:Any]]()
for patch in result.patches {
    let r=patch.pixelRect
    output.draw(patch.image,in:CGRect(x:r.minX,y:Double(height)-r.maxY,width:r.width,height:r.height))
    guard patch.word.lowercased()=="watermark" else { continue }
    let truth=expected.min { a,b in
        hypot(a.rect.midX-r.midX,a.rect.midY-r.midY)<hypot(b.rect.midX-r.midX,b.rect.midY-r.midY)
    }!
    let dx=patch.prefixRect.minX-truth.prefixStart
    let endError=patch.prefixRect.maxX-truth.prefixEnd
    records.append(["fixture":truth.label,"word":patch.word,"prefix":patch.prefix,"left_error_px":dx,"right_error_px":endError,"font":patch.fontName,"fit":patch.fitScore])
    print("\(truth.label): \(patch.prefix) left=\(String(format:"%.2f",dx)) end=\(String(format:"%.2f",endError)) fit=\(String(format:"%.3f",patch.fitScore)) \(patch.fontName)")
    check(patch.prefix=="wate","Wrong prefix")
    check(abs(dx)<4,"Prefix did not start at w")
    check(abs(endError)<6,"Prefix extended past expected wate")
    // No transparent glow and no modifications to the suffix.
    let rgba=patch.image.dataProvider!.data! as Data
    rgba.withUnsafeBytes { raw in
        let p=raw.baseAddress!.assumingMemoryBound(to:UInt8.self)
        for y in 0..<patch.image.height { for x in 0..<patch.image.width {
            check(p[y*patch.image.bytesPerRow+x*4+3]==255,"Native patch must be opaque")
        }}
    }
}
save(output.makeImage()!,"regression-enhanced.png")
let request=VNRecognizeTextRequest();request.recognitionLevel = .fast;request.recognitionLanguages=["en-US"];request.usesLanguageCorrection=false
try VNImageRequestHandler(cgImage:frame.image!,orientation:.up).perform([request])
var legacy=[[String:Any]]()
for obs in request.results ?? [] {
    guard let text=obs.topCandidates(1).first,let range=text.string.range(of:"watermark",options:.caseInsensitive),
          let box=try? text.boundingBox(for:range.lowerBound..<text.string.index(range.lowerBound,offsetBy:4)) else {continue}
    let rect=OverlayGeometry.pixels(from:box.boundingBox,width:width,height:height)
    let truth=expected.min {a,b in hypot(a.rect.midX-rect.midX,a.rect.midY-rect.midY)<hypot(b.rect.midX-rect.midX,b.rect.midY-rect.midY)}!
    legacy.append(["fixture":truth.label,"prefix_left_error_px":rect.minX-truth.prefixStart])
}
// Refreshing unchanged content must not invalidate existing or in-flight presentation.
var gate=FreshnessGate();gate.changed(at:0)
let token=gate.begin(at:0.2);gate.requestRefresh()
check(gate.accepts(token,at:0.3),"Soft refresh invalidated an in-flight result")
check(gate.completed(token,at:0.3),"Could not publish the unchanged frame")
for i in 1...20 { let version=gate.revision;gate.requestRefresh();check(gate.revision==version,"Refresh changed screen revision");check(gate.ready(at:Double(i)+1),"Refresh imposed blank settle interval") }
let report:[String:Any]=["sentence":sentence,"watermark_emitted":records.count,"expected_variants":expected.count,"native_patches":result.patches.count,"watermarks":records,
    "legacy_partial_boxes":legacy,"checks":checks,"ocr_ms":result.ocrMilliseconds,"native_render_ms":result.maskMilliseconds,"scope":"Synthetic images only; no screen capture or live GUI testing."]
try JSONSerialization.data(withJSONObject:report,options:[.prettyPrinted,.sortedKeys]).write(to:folder.appendingPathComponent("regression.json"))
check(records.count>=15,"Too many watermark fixtures were skipped")
print("PASS: \(records.count)/\(expected.count) watermark fixtures; \(checks) assertions. OCR \(result.ocrMilliseconds) ms; native render \(result.maskMilliseconds) ms.")
