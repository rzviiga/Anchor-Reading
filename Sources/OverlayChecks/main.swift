import Foundation
import CoreGraphics
import AnchorOverlayCore

var count=0
func check(_ condition: @autoclosure () -> Bool, _ message:String) {
    guard condition() else { fatalError(message) };count+=1
}
let text="I am reading quietly. Don't reader’s café 中文 'hello' international."
check(ReadingPolicy().prefixes(in:text).map{String(text[$0])} == ["I","a","rea","qui","Do","rea","he","inte"],"English prefixes / apostrophes / Unicode")
let word="international"
check(ReadingPolicy(ratio:0.5,maxLetters:1).prefixes(in:word).map{String(word[$0])} == ["i"],"Single-initial mode")
var gate=FreshnessGate();gate.changed(at:1)
check(!gate.ready(at:1.05),"Debounce");check(gate.ready(at:1.11),"Settled frame")
let old=gate.begin(at:1.11);gate.interacted(at:1.15)
check(!gate.completed(old,at:1.6),"Reject obsolete result after scrolling")
check(!gate.ready(at:1.30),"Wait after final scroll");check(gate.ready(at:1.34),"Recover after final scroll")
let current=gate.begin(at:1.34)
check(gate.completed(current,at:1.50),"Accept fresh result");check(!gate.ready(at:2),"Idle screen does not continuously OCR")
var rapid=FreshnessGate()
for i in 0..<240 { let t=Double(i)/120;rapid.changed(at:t);check(!rapid.ready(at:t+0.005),"120Hz scrolling should not queue OCR") }
check(rapid.ready(at:2.2),"Recognize only after movement settles")
let token=rapid.begin(at:2.2);rapid.changed(at:2.21)
check(!rapid.completed(token,at:2.5),"Screen change invalidates work")
let pixels=OverlayGeometry.pixels(from:CGRect(x:0.1,y:0.7,width:0.2,height:0.1),width:2000,height:1000)
check(abs(pixels.minX-200)<0.001 && abs(pixels.minY-200)<0.001,"Vision top-left mapping")
let points=OverlayGeometry.points(from:pixels,pixelWidth:2000,pixelHeight:1000,screenSize:CGSize(width:1000,height:500))
check(abs(points.minY-100)<0.001 && abs(points.width-200)<0.001,"Retina local coordinates")
func fixture(light:Bool,stroke:Bool) -> PixelFrame {
    let w=40,h=30,bg:UInt8=light ? 240 : 20,fg:UInt8=light ? 25 : 235
    var data=[UInt8](repeating:bg,count:w*h*4)
    for y in 0..<h { for x in 0..<w {
        let i=(y*w+x)*4;data[i+3]=255
        if stroke && ((x>=12 && x<=14 && y>=8 && y<=22) || (x>=12 && x<=22 && y>=8 && y<=10)) { data[i]=fg;data[i+1]=fg;data[i+2]=fg }
    }}
    return PixelFrame(bytes:Data(data),width:w,height:h,stride:w*4)
}
for light in [true,false] {
    let f=fixture(light:light,stroke:true)
    check(StrokeMask.make(frame:f,rect:CGRect(x:10,y:6,width:15,height:19),strength:0.7) != nil,"Stroke enhancement on both themes")
    check(!f.signature.differs(from:f.signature),"Same pixels remain stable")
    check(f.signature.differs(from:fixture(light:light,stroke:false).signature),"Detect changed text")
}
check(StrokeMask.make(frame:fixture(light:true,stroke:false),rect:CGRect(x:10,y:6,width:15,height:19),strength:0.7) == nil,"Skip blank backgrounds")
check(StrokeMask.make(frame:fixture(light:true,stroke:true),rect:CGRect(x:-50,y:-50,width:2,height:2),strength:0.7) == nil,"Clip invalid OCR boxes")
print("Passed \(count) checks: prefix policy, 120Hz event burst, stale work rejection, quiet-screen caching, coordinates, light/dark stroke masks.")
