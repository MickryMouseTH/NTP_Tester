// สร้างโลโก้/ไอคอนแอป 1024x1024 PNG: swift make_icon.swift <output.png>
// แนวคิด: หน้าปัดนาฬิกา (เวลา) ล้อมด้วยลูกศรซิงก์สองเส้น (การเทียบเวลา NTP ระหว่างสองเซิร์ฟเวอร์)
import AppKit

let size: CGFloat = 1024
let out = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "icon.png"
let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(size), pixelsHigh: Int(size), bitsPerSample: 8,
                           samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
                           bytesPerRow: 0, bitsPerPixel: 0)!
NSGraphicsContext.saveGraphicsState()
NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)

func rgb(_ hex: Int, _ a: CGFloat = 1) -> NSColor {
    NSColor(srgbRed: CGFloat((hex >> 16) & 0xFF) / 255, green: CGFloat((hex >> 8) & 0xFF) / 255,
            blue: CGFloat(hex & 0xFF) / 255, alpha: a)
}
let c = NSPoint(x: size / 2, y: size / 2)
func pt(_ deg: CGFloat, _ r: CGFloat) -> NSPoint {
    let a = deg * .pi / 180
    return NSPoint(x: c.x + cos(a) * r, y: c.y + sin(a) * r)
}

// ── พื้นหลัง squircle (ขอบ ~10% ตามแนวทางไอคอน macOS) ──
let inset: CGFloat = 100
let rect = NSRect(x: inset, y: inset, width: size - 2 * inset, height: size - 2 * inset)
let bg = NSBezierPath(roundedRect: rect, xRadius: 185, yRadius: 185)

NSGraphicsContext.saveGraphicsState()
let drop = NSShadow()
drop.shadowColor = NSColor.black.withAlphaComponent(0.30)
drop.shadowBlurRadius = 28
drop.shadowOffset = NSSize(width: 0, height: -12)
drop.set()
rgb(0x0B1736).setFill()
bg.fill()
NSGraphicsContext.restoreGraphicsState()

NSGradient(colors: [rgb(0x0A1230), rgb(0x10306E), rgb(0x1668C9)])!.draw(in: bg, angle: 90)

// แสงเรืองจาง ๆ หลังหน้าปัด
NSGraphicsContext.saveGraphicsState()
bg.addClip()
NSGradient(colors: [rgb(0x4FD8FF, 0.38), rgb(0x4FD8FF, 0)])!
    .draw(fromCenter: c, radius: 0, toCenter: c, radius: 430, options: [])
NSGraphicsContext.restoreGraphicsState()

// ── ลูกศรซิงก์สองเส้น หมุนตามเข็มนาฬิกา ──
let ringR: CGFloat = 290
let ringW: CGFloat = 56
func syncArrow(from start: CGFloat, to end: CGFloat, color: NSColor) {
    color.setStroke()
    color.setFill()
    let arc = NSBezierPath()
    arc.appendArc(withCenter: c, radius: ringR, startAngle: start, endAngle: end, clockwise: true)
    arc.lineWidth = ringW
    arc.lineCapStyle = .round
    arc.stroke()
    // หัวลูกศรชี้ตามแนวสัมผัส (ตามเข็ม)
    let a = end * .pi / 180
    let t = NSPoint(x: sin(a), y: -cos(a))
    let base = pt(end, ringR)
    let head = NSBezierPath()
    head.move(to: pt(end, ringR + 70))
    head.line(to: pt(end, ringR - 70))
    head.line(to: NSPoint(x: base.x + t.x * 118, y: base.y + t.y * 118))
    head.close()
    head.lineJoinStyle = .round
    head.lineWidth = 16
    head.fill()
    head.stroke()
}
syncArrow(from: 158, to: 38, color: rgb(0x5FE3FF))    // ฟ้า = เซิร์ฟเวอร์ที่ทดสอบ
syncArrow(from: -22, to: -142, color: rgb(0x6DF5A6))  // เขียว = เซิร์ฟเวอร์อ้างอิง

// ── หน้าปัดนาฬิกา ──
let faceR: CGFloat = 196
let face = NSBezierPath(ovalIn: NSRect(x: c.x - faceR, y: c.y - faceR, width: faceR * 2, height: faceR * 2))
NSGraphicsContext.saveGraphicsState()
let faceShadow = NSShadow()
faceShadow.shadowColor = NSColor.black.withAlphaComponent(0.35)
faceShadow.shadowBlurRadius = 30
faceShadow.shadowOffset = NSSize(width: 0, height: -10)
faceShadow.set()
NSColor.white.setFill()
face.fill()
NSGraphicsContext.restoreGraphicsState()
NSGradient(starting: rgb(0xFFFFFF), ending: rgb(0xDCE8F7))!.draw(in: face, angle: -90)

let ink = rgb(0x0E1F47)
ink.setStroke()
for i in 0..<12 {
    let major = i % 3 == 0
    let tick = NSBezierPath()
    tick.move(to: pt(CGFloat(i) * 30, major ? 138 : 152))
    tick.line(to: pt(CGFloat(i) * 30, 170))
    tick.lineWidth = major ? 15 : 8
    tick.lineCapStyle = .round
    tick.stroke()
}

func hand(_ clockDeg: CGFloat, length: CGFloat, tail: CGFloat = 0, width: CGFloat, color: NSColor) {
    let deg = 90 - clockDeg
    let p = NSBezierPath()
    p.move(to: pt(deg + 180, tail))
    p.line(to: pt(deg, length))
    p.lineWidth = width
    p.lineCapStyle = .round
    color.setStroke()
    p.stroke()
}
hand(305, length: 88, width: 24, color: ink)                              // เข็มชั่วโมง
hand(60, length: 128, width: 17, color: ink)                              // เข็มนาที
hand(205, length: 140, tail: 34, width: 8, color: rgb(0xFF6B3D))          // เข็มวินาที

rgb(0xFF6B3D).setFill()
NSBezierPath(ovalIn: NSRect(x: c.x - 19, y: c.y - 19, width: 38, height: 38)).fill()
NSColor.white.setFill()
NSBezierPath(ovalIn: NSRect(x: c.x - 7, y: c.y - 7, width: 14, height: 14)).fill()

NSGraphicsContext.restoreGraphicsState()
try! rep.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: out))
