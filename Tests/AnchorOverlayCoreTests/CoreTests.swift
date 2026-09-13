import XCTest
import CoreGraphics
@testable import AnchorOverlayCore

final class CoreTests:XCTestCase {
    func testPrefixesAndUnicode() {
        let text="I am reading quietly. Don't reader’s café 中文 'hello' international."
        let prefixes=ReadingPolicy().prefixes(in:text).map{String(text[$0])}
        XCTAssertEqual(prefixes,["I","a","rea","qui","Do","rea","he","inte"])
        XCTAssertEqual(ReadingPolicy(ratio:0.5,maxLetters:1).prefixes(in:"reading").count,1)
    }
    func testScrollInvalidatesInFlightOCRAndRequiresSettling() {
        var gate=FreshnessGate();gate.changed(at:1)
        XCTAssertFalse(gate.ready(at:1.05));XCTAssertTrue(gate.ready(at:1.11))
        let old=gate.begin(at:1.11)
        gate.interacted(at:1.15)
        XCTAssertFalse(gate.completed(old,at:1.6))
        XCTAssertFalse(gate.ready(at:1.30));XCTAssertTrue(gate.ready(at:1.34))
        let current=gate.begin(at:1.34)
        XCTAssertTrue(gate.completed(current,at:1.50));XCTAssertFalse(gate.ready(at:2))
    }
    func testRapidChangesNeverBuildOCRBacklog() {
        var gate=FreshnessGate()
        for i in 0..<120 { let t=Double(i)/60;gate.changed(at:t);XCTAssertFalse(gate.ready(at:t+0.01)) }
        XCTAssertTrue(gate.ready(at:2.2))
        let token=gate.begin(at:2.2);gate.changed(at:2.21)
        XCTAssertFalse(gate.completed(token,at:2.5))
    }
    func testGeometryAndNegativeMonitorOrigins() {
        let pixels=OverlayGeometry.pixels(from:CGRect(x:0.1,y:0.7,width:0.2,height:0.1),width:2000,height:1000)
        XCTAssertEqual(pixels.minX,200,accuracy:0.001);XCTAssertEqual(pixels.minY,200,accuracy:0.001)
        let points=OverlayGeometry.points(from:pixels,pixelWidth:2000,pixelHeight:1000,screenSize:CGSize(width:1000,height:500))
        XCTAssertEqual(points.minY,100,accuracy:0.001)
        // Patch coordinates are local; negative external-display origins never enter OCR math.
        XCTAssertEqual(points.width,200,accuracy:0.001)
    }
    private func fixture(light:Bool,stroke:Bool) -> PixelFrame {
        let w=40,h=30,bg:UInt8=light ? 240 : 20,fg:UInt8=light ? 25 : 235
        var data=[UInt8](repeating:bg,count:w*h*4)
        for y in 0..<h { for x in 0..<w { let i=(y*w+x)*4;data[i+3]=255
            if stroke && ((x>=12 && x<=14 && y>=8 && y<=22) || (x>=12 && x<=22 && y>=8 && y<=10)) { data[i]=fg;data[i+1]=fg;data[i+2]=fg }
        }}
        return PixelFrame(bytes:Data(data),width:w,height:h,stride:w*4)
    }
    func testStrokeMasksOnBothThemesAndBlankSkip() {
        for light in [true,false] {
            let frame=fixture(light:light,stroke:true)
            let patch=StrokeMask.make(frame:frame,rect:CGRect(x:10,y:6,width:15,height:19),strength:0.7)
            XCTAssertNotNil(patch)
            XCTAssertTrue(patch!.pixelRect.minX>=0)
        }
        XCTAssertNil(StrokeMask.make(frame:fixture(light:true,stroke:false),rect:CGRect(x:10,y:6,width:15,height:19),strength:0.7))
    }
    func testSignatureChangeDetection() {
        let empty=fixture(light:true,stroke:false), text=fixture(light:true,stroke:true)
        XCTAssertFalse(empty.signature.differs(from:empty.signature))
        XCTAssertTrue(empty.signature.differs(from:text.signature))
    }
}
