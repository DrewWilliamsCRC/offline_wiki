// Draws Wiki Reader's iOS icon: a row of encyclopedia volumes on a shelf, the last one leaning.
// Pure black on white, with no alpha channel, which App Store Connect requires. It replaced a
// serif W that looked too much like the Wikipedia app's own icon. Redraw it with:
//   swift ios/scripts/draw-icon.swift ios/App/Assets.xcassets/AppIcon.appiconset/icon-1024.png
import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

let args = CommandLine.arguments
let out = args[1]
let size = args.count > 2 ? Int(args[2])! : 1024
let s = CGFloat(size) / 1024 // everything below is in a 1024 square, y down

struct Book { var x: CGFloat; var w: CGFloat; var h: CGFloat; var lean: CGFloat } // lean in degrees, top to the left

let shelfY: CGFloat = 790
let books = [
    Book(x: 0, w: 118, h: 520, lean: 0),
    Book(x: 132, w: 138, h: 590, lean: 0),
    Book(x: 284, w: 108, h: 480, lean: 0),
    Book(x: 0, w: 118, h: 430, lean: 14), // placed against the third below
]

// Corners of a book whose bottom-right corner is at (rx, shelfY), tilted left by `lean`.
func corners(_ b: Book, rx: CGFloat) -> [CGPoint] {
    let t = b.lean * .pi / 180
    let up = CGPoint(x: -sin(t), y: -cos(t)), left = CGPoint(x: -cos(t), y: sin(t))
    let br = CGPoint(x: rx, y: shelfY)
    let bl = CGPoint(x: br.x + left.x * b.w, y: br.y + left.y * b.w)
    let tl = CGPoint(x: bl.x + up.x * b.h, y: bl.y + up.y * b.h)
    let tr = CGPoint(x: br.x + up.x * b.h, y: br.y + up.y * b.h)
    return [bl, br, tr, tl]
}

// The leaning book rests its top-left corner against the third book's right side.
let third = books[2], leaning = books[3]
let t = leaning.lean * .pi / 180
let rx = third.x + third.w + 3 + leaning.w * cos(t) + leaning.h * sin(t)

var shapes: [[CGPoint]] = books.prefix(3).map { corners($0, rx: $0.x + $0.w) }
shapes.append(corners(leaning, rx: rx))

// Centre the group (books and shelf) in the square.
let xs = shapes.flatMap { $0.map(\.x) }, ys = shapes.flatMap { $0.map(\.y) }
let shelfPad: CGFloat = 46, shelfH: CGFloat = 34
let minX = xs.min()! - shelfPad, maxX = xs.max()! + shelfPad
let minY = ys.min()!, maxY = shelfY + shelfH
let dx = 512 - (minX + maxX) / 2, dy = 512 - (minY + maxY) / 2

let ctx = CGContext(data: nil, width: size, height: size, bitsPerComponent: 8, bytesPerRow: 0,
                    space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)!
ctx.setFillColor(CGColor(red: 1, green: 1, blue: 1, alpha: 1))
ctx.fill(CGRect(x: 0, y: 0, width: size, height: size))
ctx.translateBy(x: 0, y: CGFloat(size))
ctx.scaleBy(x: s, y: -s)
ctx.translateBy(x: dx, y: dy)

let black = CGColor(red: 0, green: 0, blue: 0, alpha: 1), white = CGColor(red: 1, green: 1, blue: 1, alpha: 1)
func poly(_ p: [CGPoint], _ c: CGColor) {
    ctx.setFillColor(c); ctx.beginPath(); ctx.addLines(between: p); ctx.closePath(); ctx.fillPath()
}
// A band across a book, `from`..`to` measured up from its bottom edge.
func band(_ c: [CGPoint], _ from: CGFloat, _ to: CGFloat, _ h: CGFloat) {
    func at(_ a: CGPoint, _ b: CGPoint, _ f: CGFloat) -> CGPoint { CGPoint(x: a.x + (b.x - a.x) * f, y: a.y + (b.y - a.y) * f) }
    let (bl, br, tr, tl) = (c[0], c[1], c[2], c[3])
    poly([at(bl, tl, from / h), at(br, tr, from / h), at(br, tr, to / h), at(bl, tl, to / h)], white)
}

for (i, c) in shapes.enumerated() {
    poly(c, black)
    let h = books[i].h
    // Two thin bands near each end, as on a bound encyclopedia's spine, and a label between.
    band(c, 46, 60, h); band(c, 78, 86, h)
    band(c, h - 86, h - 78, h); band(c, h - 60, h - 46, h)
    let mid = h * 0.62
    let w = books[i].w
    let lb = c[0], rb = c[1], tl = c[3], tr = c[2]
    func pt(_ u: CGFloat, _ v: CGFloat) -> CGPoint { // u across 0..1, v up in points
        let bx = lb.x + (rb.x - lb.x) * u, by = lb.y + (rb.y - lb.y) * u
        let ux = (tl.x - lb.x) / h, uy = (tl.y - lb.y) / h
        return CGPoint(x: bx + ux * v, y: by + uy * v)
    }
    let inset = 26 / w
    poly([pt(inset, mid - 34), pt(1 - inset, mid - 34), pt(1 - inset, mid + 34), pt(inset, mid + 34)], white)
    _ = tr
}
// The shelf.
ctx.setFillColor(black)
ctx.fill(CGRect(x: minX, y: shelfY, width: maxX - minX, height: shelfH))

let image = ctx.makeImage()!
let dest = CGImageDestinationCreateWithURL(URL(fileURLWithPath: out) as CFURL, UTType.png.identifier as CFString, 1, nil)!
CGImageDestinationAddImage(dest, image, nil)
CGImageDestinationFinalize(dest)
