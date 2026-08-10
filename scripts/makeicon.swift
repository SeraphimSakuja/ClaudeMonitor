import AppKit
import CoreGraphics

// Erzeugt das ClaudeMonitor-App-Icon als 1024×1024-PNG.
//
// Motiv: Ring-Messer auf dunklem Rundquadrat — dieselbe Aussage wie die
// Auslastungsbalken im Detailfenster (wie viel Kontingent ist noch da), und
// als geschlossene Form auch bei 16 px noch eindeutig. Bewusst KEIN Text und
// keine feinen Details: Alles unter ~3 px Strichstärke verschwindet in der
// Menüleistengröße.

let canvas: CGFloat = 1024
// Apples Rundquadrat-Raster für macOS: Körper 824×824, zentriert, Radius 185.4.
let bodySize: CGFloat = 824
let bodyOrigin = (canvas - bodySize) / 2
let cornerRadius: CGFloat = 185.4

let colorSpace = CGColorSpaceCreateDeviceRGB()
guard let ctx = CGContext(data: nil, width: Int(canvas), height: Int(canvas),
                          bitsPerComponent: 8, bytesPerRow: 0, space: colorSpace,
                          bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else {
    fatalError("Kontext konnte nicht erzeugt werden")
}
ctx.setAllowsAntialiasing(true)
ctx.interpolationQuality = .high

func rgb(_ r: CGFloat, _ g: CGFloat, _ b: CGFloat, _ a: CGFloat = 1) -> CGColor {
    CGColor(colorSpace: colorSpace, components: [r / 255, g / 255, b / 255, a])!
}

let bodyRect = CGRect(x: bodyOrigin, y: bodyOrigin, width: bodySize, height: bodySize)
let bodyPath = CGPath(roundedRect: bodyRect, cornerWidth: cornerRadius,
                      cornerHeight: cornerRadius, transform: nil)

// --- Untergrund: dunkler Verlauf, oben etwas heller (Lichteinfall von oben) ---
ctx.saveGState()
ctx.addPath(bodyPath)
ctx.clip()
let bg = CGGradient(colorsSpace: colorSpace,
                    colors: [rgb(58, 62, 74), rgb(26, 28, 35)] as CFArray,
                    locations: [0, 1])!
ctx.drawLinearGradient(bg,
                       start: CGPoint(x: 0, y: canvas),
                       end: CGPoint(x: 0, y: 0),
                       options: [])
ctx.restoreGState()

// --- Ring ---
let center = CGPoint(x: canvas / 2, y: canvas / 2)
let radius: CGFloat = 236
let lineWidth: CGFloat = 104

// Spur: der noch nicht verbrauchte Teil. Dezent, aber sichtbar — ohne sie
// wirkt der Bogen wie ein zufälliges Fragment statt wie ein Messwert.
ctx.setLineWidth(lineWidth)
ctx.setLineCap(.round)
ctx.setStrokeColor(rgb(255, 255, 255, 0.16))
ctx.addArc(center: center, radius: radius, startAngle: 0, endAngle: .pi * 2, clockwise: false)
ctx.strokePath()

// Messwert: rund 72 %, im Uhrzeigersinn ab oben. Ein voller oder fast leerer
// Ring wäre mehrdeutig — 72 % liest sofort als „Anzeige", nicht als Symbol.
let startAngle = CGFloat.pi / 2              // oben
let sweep = CGFloat.pi * 2 * 0.72
ctx.saveGState()
ctx.setLineWidth(lineWidth)
ctx.setLineCap(.round)
ctx.addArc(center: center, radius: radius,
           startAngle: startAngle, endAngle: startAngle - sweep, clockwise: true)
ctx.replacePathWithStrokedPath()
ctx.clip()
// Verlauf Grün → Bernstein: die Ampel der App, ohne eine Stufe zu behaupten.
let arcGradient = CGGradient(colorsSpace: colorSpace,
                             colors: [rgb(48, 209, 88), rgb(255, 196, 60)] as CFArray,
                             locations: [0, 1])!
ctx.drawLinearGradient(arcGradient,
                       start: CGPoint(x: center.x - radius, y: center.y + radius),
                       end: CGPoint(x: center.x + radius, y: center.y - radius),
                       options: [.drawsBeforeStartLocation, .drawsAfterEndLocation])
ctx.restoreGState()

// --- Kern: der Ampelpunkt aus der Menüleiste ---
let dotRadius: CGFloat = 88
ctx.setFillColor(rgb(48, 209, 88))
ctx.addArc(center: center, radius: dotRadius, startAngle: 0, endAngle: .pi * 2, clockwise: false)
ctx.fillPath()

guard let image = ctx.makeImage() else { fatalError("Bild konnte nicht erzeugt werden") }
let rep = NSBitmapImageRep(cgImage: image)
rep.size = NSSize(width: canvas, height: canvas)
guard let png = rep.representation(using: .png, properties: [:]) else {
    fatalError("PNG-Kodierung fehlgeschlagen")
}
try png.write(to: URL(fileURLWithPath: CommandLine.arguments[1]))
print("geschrieben: \(CommandLine.arguments[1])")
