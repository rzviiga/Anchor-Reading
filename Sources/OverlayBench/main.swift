import Foundation
import CoreGraphics
import CoreText
import ImageIO
import UniformTypeIdentifiers
import AnchorOverlayCore

func save(_ image: CGImage, to url: URL) {
    guard let dest=CGImageDestinationCreateWithURL(url as CFURL,UTType.png.identifier as CFString,1,nil) else { fatalError("Cannot create PNG") }
    CGImageDestinationAddImage(dest,image,nil)
    precondition(CGImageDestinationFinalize(dest))
}

func scene(scale: Double) -> PixelFrame {
    let width=Int(1440*scale),height=Int(900*scale)
    let info=CGBitmapInfo.byteOrder32Little.rawValue | CGImageAlphaInfo.premultipliedFirst.rawValue
    let c=CGContext(data:nil,width:width,height:height,bitsPerComponent:8,bytesPerRow:width*4,space:CGColorSpaceCreateDeviceRGB(),bitmapInfo:info)!
    c.scaleBy(x:scale,y:scale)
    c.setFillColor(CGColor(red:0.97,green:0.96,blue:0.93,alpha:1));c.fill(CGRect(x:0,y:0,width:1440,height:900))
    c.setFillColor(CGColor(red:0.10,green:0.14,blue:0.13,alpha:1));c.fill(CGRect(x:740,y:0,width:700,height:900))
    func text(_ text:String,_ x:Double,_ top:Double,_ size:Double,_ dark:Bool,_ serif:Bool=false) {
        let font=CTFontCreateWithName((serif ? "Georgia" : "Helvetica") as CFString,size,nil)
        let color=dark ? CGColor(red:0.92,green:0.95,blue:0.92,alpha:1) : CGColor(red:0.13,green:0.19,blue:0.16,alpha:1)
        let attributes:[NSAttributedString.Key:Any]=[NSAttributedString.Key(kCTFontAttributeName as String):font,NSAttributedString.Key(kCTForegroundColorAttributeName as String):color]
        c.textPosition=CGPoint(x:x,y:900-top-size)
        CTLineDraw(CTLineCreateWithAttributedString(NSAttributedString(string:text,attributes:attributes)),c)
    }
    text("Anchor Overlay",40,30,32,false);text("Dark background",780,30,32,true)
    text("Synthetic screen. No personal screen content.",40,84,16,false)
    text("Original glyphs, enhanced beginnings.",780,84,16,true)
    let lines=["Reading gives us time to explore unfamiliar ideas.","A small change can make the beginning stand out.","Don't replace the whole word or alter its position.","Keep the reader's own typeface and line spacing.","Scrolling should feel natural, responsive and smooth.","I am reading quietly. Office, affinity, international.","Typography should support attention and understanding.","Try different settings and choose a comfortable rhythm."]
    for i in 0..<19 {
        let size:Double = i%4==0 ? 13 : 18
        text(lines[i%lines.count],40,136+Double(i)*35,size,false,i%3==0)
        text(lines[(i+2)%lines.count],780,136+Double(i)*35,size,true,i%3==0)
    }
    return PixelFrame(bytes:Data(bytes:c.data!,count:width*height*4),width:width,height:height,stride:width*4)
}

let args=CommandLine.arguments
let root=URL(fileURLWithPath:args.count>1 ? args[1] : "qa",isDirectory:true)
try FileManager.default.createDirectory(at:root,withIntermediateDirectories:true)
var reports=[[String:Any]]()
let engine=EnhancementEngine()
for scale in [1.0,1.5,2.0] {
    let frame=scene(scale:scale)
    var times=[Double](),ocr=[Double](),masks=[Double]()
    var final:RecognitionResult?
    for _ in 0..<6 {
        let result=try engine.recognize(frame)
        times.append(result.totalMilliseconds);ocr.append(result.ocrMilliseconds);masks.append(result.maskMilliseconds);final=result
    }
    let result=final!
    guard result.patches.count>15 else { fatalError("OCR fixture did not produce enough accents: \(result.patches.count)") }
    let sorted=times.dropFirst().sorted()
    let report:[String:Any]=["scale":scale,"width":frame.width,"height":frame.height,"patches":result.patches.count,
        "cold_ms":times[0],"warm_median_ms":sorted[sorted.count/2],"warm_max_ms":sorted.last!,"all_total_ms":times,
        "last_ocr_ms":ocr.last!,"last_masks_ms":masks.last!]
    reports.append(report)
    print(String(format:"%.1fx: %d accents | cold %.1f ms | warm median %.1f ms | max %.1f ms",scale,result.patches.count,times[0],sorted[sorted.count/2],sorted.last!))
    if scale==1.5 {
        save(frame.image!,to:root.appendingPathComponent("synthetic-original.png"))
        let c=CGContext(data:nil,width:frame.width,height:frame.height,bitsPerComponent:8,bytesPerRow:frame.width*4,space:CGColorSpaceCreateDeviceRGB(),bitmapInfo:CGImageAlphaInfo.premultipliedLast.rawValue)!
        c.draw(frame.image!,in:CGRect(x:0,y:0,width:frame.width,height:frame.height))
        for patch in result.patches {
            let r=patch.pixelRect
            c.draw(patch.image,in:CGRect(x:r.minX,y:Double(frame.height)-r.maxY,width:r.width,height:r.height))
        }
        save(c.makeImage()!,to:root.appendingPathComponent("synthetic-enhanced.png"))
    }
}
let data=try JSONSerialization.data(withJSONObject:["fixture":"Generated two-pane 1440x900 screen with English, light/dark backgrounds, 13/18/32 pt text", "system":ProcessInfo.processInfo.operatingSystemVersionString,"samples":reports,"scope":"OCR and stroke-mask preparation only. Excludes screen capture, settle delay, compositor, and live scrolling."],options:[.prettyPrinted,.sortedKeys])
try data.write(to:root.appendingPathComponent("benchmark.json"))
