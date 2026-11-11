import AppKit
import ImageIO
let output = URL(fileURLWithPath:CommandLine.arguments[1],isDirectory:true)
try FileManager.default.createDirectory(at:output,withIntermediateDirectories:true)
func makeIcon(_ dimension:Int) throws {
    let colorSpace = CGColorSpace(name:CGColorSpace.sRGB)!
    let context = CGContext(data:nil,width:dimension,height:dimension,bitsPerComponent:8,bytesPerRow:0,space:colorSpace,bitmapInfo:CGImageAlphaInfo.premultipliedLast.rawValue)!
    context.scaleBy(x:CGFloat(dimension)/1024,y:CGFloat(dimension)/1024)
    context.setFillColor(CGColor(red:36/255,green:117/255,blue:232/255,alpha:1))
    context.addPath(CGPath(roundedRect:CGRect(x:64,y:64,width:896,height:896),cornerWidth:196,cornerHeight:196,transform:nil));context.fillPath()
    context.translateBy(x:512,y:512);context.rotate(by:.pi/4);context.scaleBy(x:36,y:36)
    context.setStrokeColor(CGColor(gray:1,alpha:1));context.setLineWidth(1.8);context.setLineCap(.round);context.setLineJoin(.round)
    context.move(to:CGPoint(x:-1,y:2.5));context.addLine(to:CGPoint(x:-4,y:2.5))
    context.addCurve(to:CGPoint(x:-4,y:-2.5),control1:CGPoint(x:-7.33,y:2.5),control2:CGPoint(x:-7.33,y:-2.5));context.addLine(to:CGPoint(x:-1,y:-2.5))
    context.move(to:CGPoint(x:1,y:2.5));context.addLine(to:CGPoint(x:4,y:2.5))
    context.addCurve(to:CGPoint(x:4,y:-2.5),control1:CGPoint(x:7.33,y:2.5),control2:CGPoint(x:7.33,y:-2.5));context.addLine(to:CGPoint(x:1,y:-2.5))
    context.move(to:CGPoint(x:-2,y:0));context.addLine(to:CGPoint(x:2,y:0));context.strokePath()
    let image = context.makeImage()!
    let data = NSBitmapImageRep(cgImage:image).representation(using:.png,properties:[:])!
    try data.write(to:output.appendingPathComponent("Harbor-\(dimension).png"))
}
for size in [16,32,64,128,256,512,1024] { try makeIcon(size) }
