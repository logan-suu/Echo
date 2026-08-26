// ==========================================
// OCR fixture generator — renders text images for WP5 OCR channel tests.
// Usage: swift Scripts/generate_ocr_fixtures.swift <output-dir>
// All fixtures are self-generated (CC0); SHA256 manifests are produced separately.
// ==========================================

import AppKit

struct FixtureSpec {
    let name: String
    let lines: [(text: String, font: NSFont)]
    let background: NSColor
    let foreground: NSColor
    let rotationDegrees: CGFloat
    let size: NSSize
}

func render(_ spec: FixtureSpec, to url: URL) throws {
    let image = NSImage(size: spec.size)
    image.lockFocusFlipped(true)

    spec.background.setFill()
    NSBezierPath(rect: NSRect(origin: .zero, size: spec.size)).fill()

    let paragraph = NSMutableParagraphStyle()
    paragraph.lineBreakMode = .byWordWrapping
    paragraph.alignment = .left

    var y: CGFloat = 40
    for line in spec.lines {
        let attrs: [NSAttributedString.Key: Any] = [
            .font: line.font,
            .foregroundColor: spec.foreground,
            .paragraphStyle: paragraph,
        ]
        let drawn = NSAttributedString(string: line.text, attributes: attrs)
        let bounds = drawn.boundingRect(
            with: NSSize(width: spec.size.width - 80, height: .greatestFiniteMagnitude),
            options: [.usesLineFragmentOrigin]
        )

        NSGraphicsContext.saveGraphicsState()
        let transform = NSAffineTransform()
        transform.translateX(by: spec.size.width / 2, yBy: spec.size.height / 2)
        transform.rotate(byDegrees: spec.rotationDegrees)
        transform.translateX(by: -spec.size.width / 2, yBy: -spec.size.height / 2)
        transform.concat()
        drawn.draw(at: NSPoint(x: 40, y: y))
        NSGraphicsContext.restoreGraphicsState()

        y += bounds.height + 18
    }

    image.unlockFocus()

    guard let tiff = image.tiffRepresentation,
          let rep = NSBitmapImageRep(data: tiff),
          let png = rep.representation(using: .png, properties: [:]) else {
        throw NSError(domain: "fixture-gen", code: 1,
                      userInfo: [NSLocalizedDescriptionKey: "PNG encode failed for \(spec.name)"])
    }
    try png.write(to: url)
}

let outDir = CommandLine.arguments.count > 1
    ? CommandLine.arguments[1]
    : "EchoTests/Fixtures/PhotoTextSearch/images"
try? FileManager.default.createDirectory(atPath: outDir, withIntermediateDirectories: true)

let body = NSFont.systemFont(ofSize: 34, weight: .medium)
let smallBlurry = NSFont.systemFont(ofSize: 15, weight: .regular)
let cjk = NSFont(name: "PingFangSC-Regular", size: 34) ?? body

let specs: [FixtureSpec] = [
    FixtureSpec(
        name: "screenshot-basic",
        lines: [("Quarterly Report Due Friday", body), ("Meeting Room 4B at 3pm", body)],
        background: .white, foreground: .black, rotationDegrees: 0,
        size: NSSize(width: 750, height: 420)
    ),
    FixtureSpec(
        name: "rotated-90",
        lines: [("Rotate me to read this note", body)],
        background: .white, foreground: .black, rotationDegrees: 90,
        size: NSSize(width: 600, height: 600)
    ),
    FixtureSpec(
        name: "blank-photo",
        lines: [],
        background: NSColor(calibratedWhite: 0.96, alpha: 1), foreground: .black,
        rotationDegrees: 0, size: NSSize(width: 600, height: 400)
    ),
    FixtureSpec(
        name: "low-confidence",
        lines: [("barely visible whisper text", smallBlurry)],
        background: NSColor(calibratedWhite: 0.78, alpha: 1),
        foreground: NSColor(calibratedWhite: 0.74, alpha: 1),
        rotationDegrees: 2, size: NSSize(width: 700, height: 300)
    ),
    FixtureSpec(
        name: "mixed-language",
        lines: [("每周报告周五截止", cjk), ("Sync with the team on Monday", body)],
        background: .white, foreground: .black, rotationDegrees: 0,
        size: NSSize(width: 760, height: 420)
    ),
]

for spec in specs {
    let url = URL(fileURLWithPath: outDir).appendingPathComponent("\(spec.name).png")
    try render(spec, to: url)
    print("generated \(url.path)")
}
