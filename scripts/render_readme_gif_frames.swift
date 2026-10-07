// Compose documented, synthetic-only CUA screenshots; never captures a desktop.
import AppKit
import Foundation
import ImageIO

struct DemoSequence {
    let name: String
    let title: String
    let steps: [String]
}
let sequences = [
    DemoSequence(name: "daily", title: "A daily journal for both coding agents", steps: [
        "See Codex and Claude Code together",
        "Pick a day on the calendar",
        "Filter the list by source",
        "Open an editable daily note",
        "Edit the summary and confirm it",
        "Save — the note is now confirmed"
    ]),
    DemoSequence(name: "thread", title: "Follow a thread, not just a chat", steps: [
        "Switch to the cross-day thread view",
        "Research threads show stages, not guessed percentages",
        "Open the editable task tree for a fixed goal",
        "Only human-confirmed leaf tasks count toward progress",
        "Save a version and browse daily history",
        "Revisit an earlier snapshot without calling a model"
    ]),
    DemoSequence(name: "share", title: "Turn your progress into a shareable image", steps: [
        "Choose a date range and the threads to include",
        "Choose titles and exclude a thread from this share",
        "Preview the purple progress cards",
        "Browse automatically paginated images",
        "Save PNG — the image was exported successfully"
    ])
]

guard CommandLine.arguments.count == 3 else {
    fputs("Usage: swift scripts/render_readme_gif_frames.swift <raw-demo-frames> <rendered-output>\n", stderr)
    exit(1)
}
let sourceRoot = URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true)
let outputRoot = URL(fileURLWithPath: CommandLine.arguments[2], isDirectory: true)
let manager = FileManager.default
let width = 1200, height = 900
let purple = NSColor(calibratedRed: 0.48, green: 0.30, blue: 0.80, alpha: 1)
func rect(_ x: CGFloat, _ top: CGFloat, _ w: CGFloat, _ h: CGFloat) -> NSRect {
    NSRect(x: x, y: CGFloat(height) - top - h, width: w, height: h)
}
func text(_ value: String, x: CGFloat, top: CGFloat, size: CGFloat, color: NSColor,
          weight: NSFont.Weight = .regular, availableWidth: CGFloat = 1120) {
    let paragraph = NSMutableParagraphStyle()
    paragraph.lineBreakMode = .byTruncatingTail
    (value as NSString).draw(in: rect(x, top, availableWidth, size + 12), withAttributes: [
        .font: NSFont.systemFont(ofSize: size, weight: weight), .foregroundColor: color,
        .paragraphStyle: paragraph
    ])
}
do {
    for sequence in sequences {
        let folder = outputRoot.appendingPathComponent(sequence.name, isDirectory: true)
        try manager.createDirectory(at: folder, withIntermediateDirectories: true)
        var concat = ["ffconcat version 1.0"]
        for (index, step) in sequence.steps.enumerated() {
            let filename = String(format: "%02d.png", index + 1)
            let source = sourceRoot.appendingPathComponent(sequence.name).appendingPathComponent(filename)
            guard let imageSource = CGImageSourceCreateWithURL(source as CFURL, nil),
                  let original = CGImageSourceCreateImageAtIndex(imageSource, 0, nil),
                  let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: width, pixelsHigh: height,
                    bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                    colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0),
                  let context = NSGraphicsContext(bitmapImageRep: bitmap) else {
                throw NSError(domain: "ReadmeDemo", code: 1,
                    userInfo: [NSLocalizedDescriptionKey: "Missing or invalid demo frame: \(sequence.name)/\(filename)"])
            }
            // CUA modal captures have no title bar. Remove only the main window's
            // title bar (including the capture indicator), never any app controls.
            let screenshot: CGImage
            if original.width > 2500 && CGFloat(original.width) / CGFloat(original.height) > 1.5 {
                guard let cropped = original.cropping(to: CGRect(x: 0, y: 56,
                    width: original.width, height: original.height - 56)) else {
                    throw NSError(domain: "ReadmeDemo", code: 2)
                }
                screenshot = cropped
            } else { screenshot = original }
            NSGraphicsContext.saveGraphicsState()
            NSGraphicsContext.current = context
            context.imageInterpolation = .high
            NSColor(calibratedRed: 0.965, green: 0.95, blue: 0.985, alpha: 1).setFill()
            NSBezierPath(rect: NSRect(x: 0, y: 0, width: width, height: height)).fill()
            text(sequence.title, x: 28, top: 17, size: 24, color: purple, weight: .bold)
            text("AgentJournal · English macOS demo · Synthetic data · No model calls",
                 x: 28, top: 50, size: 13, color: .darkGray)

            let stage = rect(24, 89, 1152, 698)
            NSColor.white.setFill()
            NSBezierPath(roundedRect: stage, xRadius: 12, yRadius: 12).fill()
            let scale = min((stage.width - 12) / CGFloat(screenshot.width),
                            (stage.height - 12) / CGFloat(screenshot.height))
            let size = NSSize(width: CGFloat(screenshot.width) * scale,
                              height: CGFloat(screenshot.height) * scale)
            let destination = NSRect(x: stage.midX - size.width / 2, y: stage.midY - size.height / 2,
                                     width: size.width, height: size.height)
            NSImage(cgImage: screenshot, size: .zero).draw(in: destination)
            purple.withAlphaComponent(0.15).setStroke()
            NSBezierPath(roundedRect: stage, xRadius: 12, yRadius: 12).stroke()

            purple.setFill()
            NSBezierPath(roundedRect: rect(28, 813, 75, 35), xRadius: 9, yRadius: 9).fill()
            text("\(index + 1) / \(sequence.steps.count)", x: 43, top: 819, size: 16,
                 color: .white, weight: .semibold, availableWidth: 55)
            text(step, x: 120, top: 815, size: 19, color: .black, weight: .semibold, availableWidth: 1045)
            text("Codex blue · Claude Code orange · Local-first · Nothing uploaded automatically",
                 x: 28, top: 865, size: 12, color: .darkGray)
            NSGraphicsContext.restoreGraphicsState()
            guard let png = bitmap.representation(using: .png, properties: [:]) else {
                throw NSError(domain: "ReadmeDemo", code: 3)
            }
            try png.write(to: folder.appendingPathComponent(filename), options: .atomic)
            concat.append("file '\(filename)'")
            concat.append("duration \(index == sequence.steps.count - 1 ? 3 : 2)")
        }
        // The concat demuxer needs a final file to honor the last duration.
        concat.append("file '\(String(format: "%02d.png", sequence.steps.count))'")
        try (concat.joined(separator: "\n") + "\n").write(
            to: folder.appendingPathComponent("frames.ffconcat"), atomically: true, encoding: .utf8)
        print("Rendered \(sequence.name): \(sequence.steps.count) synthetic demo frames")
    }
} catch {
    fputs("\(error.localizedDescription)\n", stderr)
    exit(1)
}
