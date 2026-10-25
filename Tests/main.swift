import AppKit
import PDFKit
import ImageIO
import CoreText
import AVFoundation
import CoreVideo
import SwiftUI

let fm = FileManager.default
let root = URL(fileURLWithPath: CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : NSTemporaryDirectory() + "Orbit-tests-" + UUID().uuidString, isDirectory: true)
try fm.createDirectory(at: root, withIntermediateDirectories: true)
let inputs = root.appendingPathComponent("inputs"), outputs = root.appendingPathComponent("outputs")
try fm.createDirectory(at: inputs, withIntermediateDirectories: true)
try fm.createDirectory(at: outputs, withIntermediateDirectories: true)
let e = ConversionEngine(outputDirectory: outputs)
var checks = 0
func require(_ value: @autoclosure () throws -> Bool, _ label: String) throws {
    guard try value() else { throw OrbitError("FAIL: " + label) }; checks += 1; print("PASS: " + label)
}
func throwsError(_ label: String, _ body: () throws -> Void) throws {
    var didThrow = false; do { try body() } catch { didThrow = true }
    try require(didThrow, label)
}
do {
    let image = CGContext(data: nil, width: 120, height: 80, bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    image.setFillColor(CGColor(red: 1, green: 0, blue: 0, alpha: 0.8)); image.fill(CGRect(x: 0, y: 0, width: 60, height: 80))
    let source = inputs.appendingPathComponent("Проверка ' $() фото.png")
    try e.imageData(image.makeImage()!, ext: "png").write(to: source)
    let original = try Data(contentsOf: source)
    for format in ConversionEngine.formats(for: source).filter({ $0.id != "pdf" }) {
        let out = try e.convert(source, to: format.id)
        let decoded = CGImageSourceCreateWithURL(out as CFURL, nil).flatMap { CGImageSourceCreateImageAtIndex($0, 0, nil) }
        try require(decoded?.width == 120 && decoded?.height == 80, "PNG → \(format.id.uppercased()) is decodable with correct dimensions")
    }
    let first = try e.convert(source, to: "jpg"), firstData = try Data(contentsOf: first)
    let second = try e.convert(source, to: "jpg")
    try require(first != second && (try Data(contentsOf: first)) == firstData, "filename collision preserves existing output")
    try require(try Data(contentsOf: source) == original, "source image unchanged")
    let joined = try e.imagesToPDF([source, source]) { _ in }
    try require(PDFDocument(url: joined)?.pageCount == 2, "two images produce a two-page PDF")
    let pages = try e.convert(joined, to: "png")
    let rendered = try fm.contentsOfDirectory(at: pages, includingPropertiesForKeys: nil)
    try require(rendered.count == 2 && rendered.allSatisfy { CGImageSourceCreateWithURL($0 as CFURL, nil) != nil }, "PDF exports every page as valid PNG")
    let jpgs = try e.convert(joined, to: "jpg")
    try require(try fm.contentsOfDirectory(at: jpgs, includingPropertiesForKeys: nil).count == 2, "PDF exports every page as JPG")
    let text = "Orbit test — проверка текста.\nSecond line."
    let textSource = inputs.appendingPathComponent("Документ ' $() \" test.txt")
    try Data(text.utf8).write(to: textSource)
    let attributed = NSAttributedString(string: text, attributes: [.font: NSFont.systemFont(ofSize: 12), .foregroundColor: NSColor.black])
    let textPDF = inputs.appendingPathComponent("text.pdf")
    try e.textPDF(attributed).write(to: textPDF)
    let extracted = try e.convert(textPDF, to: "txt")
    try require(try String(contentsOf: extracted, encoding: .utf8).contains("проверка текста"), "PDF text extraction preserves Cyrillic")
    for format in ["docx", "rtf", "html"] {
        let doc = try e.convert(textSource, to: format)
        let roundtrip = try e.convert(format == "html" ? doc.appendingPathComponent("index.html") : doc, to: "txt")
        try require(try String(contentsOf: roundtrip, encoding: .utf8).contains("проверка текста"), "TXT → \(format.uppercased()) → TXT roundtrip")
    }
    try throwsError("image-only PDF does not produce empty TXT") { _ = try e.convert(joined, to: "txt") }
    let broken = inputs.appendingPathComponent("broken.pdf"); try Data("not a pdf".utf8).write(to: broken)
    try throwsError("corrupt PDF reports an error") { _ = try e.convert(broken, to: "png") }
    let unknown = inputs.appendingPathComponent("unknown.bin"); try Data([1,2,3]).write(to: unknown)
    try require(ConversionEngine.formats(for: unknown).isEmpty, "unsupported files have no conversion choices")
    try require(ConversionEngine.commonFormats([source, textPDF]).map(\.id) == ["jpg"], "mixed selection exposes only common targets")
    let wordText = try e.convert(textPDF, to: "docx")
    let wordPlain = try e.convert(wordText, to: "txt")
    try require(try String(contentsOf: wordPlain, encoding: .utf8).contains("проверка текста"), "PDF → text-only DOCX retains Cyrillic")
    let nativePDF = try e.convert(wordText, to: "pdf")
    try require(PDFDocument(url: nativePDF)?.string?.contains("проверка текста") == true, "native DOCX → PDF works without launching Office")
    let richLong = try e.richTextPDF(longTextFixture())
    try require((PDFDocument(data: richLong)?.pageCount ?? 0) > 1, "native rich-text PDF paginates correctly")
    let attachment = NSTextAttachment()
    attachment.fileWrapper = FileWrapper(regularFileWithContents: original)
    attachment.fileWrapper?.preferredFilename = "picture.png"
    attachment.attachmentCell = NSTextAttachmentCell(imageCell: NSImage(cgImage: image.makeImage()!, size: NSSize(width: 120, height: 80)))
    let illustrated = NSMutableAttributedString(string: "A document with an image\n", attributes: [.font: NSFont.systemFont(ofSize: 12)])
    illustrated.append(NSAttributedString(attachment: attachment))
    let rtfd = inputs.appendingPathComponent("illustrated.rtfd")
    let package = try illustrated.fileWrapper(from: NSRange(location: 0, length: illustrated.length), documentAttributes: [.documentType: NSAttributedString.DocumentType.rtfd])
    try package.write(to: rtfd, options: .atomic, originalContentsURL: nil)
    let htmlPackage = try e.convert(rtfd, to: "html")
    try require(fm.fileExists(atPath: htmlPackage.appendingPathComponent("index.html").path) && (fm.enumerator(at: htmlPackage, includingPropertiesForKeys: nil)?.allObjects.count ?? 0) > 1, "HTML export retains subsidiary image files")
    let illustratedPDF = try e.convert(rtfd, to: "pdf")
    let illustratedDocument = PDFDocument(url: illustratedPDF)!
    let thumbnail = illustratedDocument.page(at: 0)!.thumbnail(of: NSSize(width: 595, height: 842), for: .mediaBox)
    let pixels = NSBitmapImageRep(data: thumbnail.tiffRepresentation!)!
    var redPixels = 0
    for y in stride(from: 0, to: pixels.pixelsHigh, by: 4) {
        for x in stride(from: 0, to: pixels.pixelsWide, by: 4) {
            if let color = pixels.colorAt(x: x, y: y)?.usingColorSpace(.deviceRGB), color.redComponent > 0.6 && color.greenComponent < 0.5 && color.blueComponent < 0.5 { redPixels += 1 }
        }
    }
    try require(redPixels > 20, "native PDF renders embedded document images")
    try throwsError("unsupported conversion is rejected") { _ = try e.convert(textPDF, to: "wav") }
    let cancelled = ConversionEngine(outputDirectory: outputs); cancelled.isCancelled = { true }
    try throwsError("cancellation stops before writing") { _ = try cancelled.convert(source, to: "jpg") }
    let longText = NSAttributedString(string: String(repeating: "A line of text for pagination.\n", count: 180), attributes: [.font: NSFont.systemFont(ofSize: 12)])
    let longPDF = try e.textPDF(longText)
    try require((PDFDocument(data: longPDF)?.pageCount ?? 0) > 1, "long text paginates across multiple PDF pages")
    let csv = inputs.appendingPathComponent("таблица.csv")
    let csvText = "name,note\r\n\"Иван, тест\",\"two\nlines\"\r\n\"quote\"\"here\",42\r\n"
    try Data(csvText.utf8).write(to: csv)
    let tsv = try e.convert(csv, to: "tsv"), csvAgain = try e.convert(tsv, to: "csv")
    try require(try ExtraConversions.parseTable(String(contentsOf: csvAgain, encoding: .utf8), separator: ",") == ExtraConversions.parseTable(csvText, separator: ","), "CSV/TSV preserve quoted separators, newlines, Unicode and escaped quotes")
    try throwsError("unclosed CSV quote reports error") { _ = try ExtraConversions.parseTable("a,\"bad", separator: ",") }
    let sub = inputs.appendingPathComponent("captions.srt")
    try Data("1\n00:00:01,000 --> 00:00:02,500\nПривет, Orbit!\n\n2\n00:00:03,000 --> 00:00:04,000\nSecond cue\n".utf8).write(to: sub)
    let vtt = try e.convert(sub, to: "vtt"), subAgain = try e.convert(vtt, to: "srt")
    try require(try String(contentsOf: vtt, encoding: .utf8).hasPrefix("WEBVTT"), "SRT → VTT adds WebVTT header")
    try require(try String(contentsOf: subAgain, encoding: .utf8).contains("00:00:01,000 --> 00:00:02,500"), "VTT → SRT preserves timestamps")
    let transcript = try e.convert(vtt, to: "txt")
    try require(try String(contentsOf: transcript, encoding: .utf8).contains("Привет, Orbit!"), "subtitles export plain transcript")
    let zip = inputs.appendingPathComponent("sample.zip")
    let folder = inputs.appendingPathComponent("archive-source")
    try fm.createDirectory(at: folder, withIntermediateDirectories: true)
    try Data("Archive payload".utf8).write(to: folder.appendingPathComponent("данные.txt"))
    try e.process("/usr/bin/ditto", ["-c", "-k", "--norsrc", folder.path, zip.path])
    let tar = try e.convert(zip, to: "tar"), gz = try e.convert(tar, to: "tar.gz"), zipAgain = try e.convert(gz, to: "zip")
    try require(try e.process("/usr/bin/tar", ["-tf", zipAgain.path]).contains("данные.txt"), "ZIP → TAR → TGZ → ZIP preserves archive contents")
    let clean = try FileTools.run(FileTools.clean, files: [source], engine: e) { _ in }
    try require(clean.count == 1 && clean[0] != source, "metadata tool produces a separate image")
    let rotated = try FileTools.run(FileTools.rotate, files: [source], engine: e) { _ in }
    let rotatedImage = try e.image(rotated[0])
    try require(rotatedImage.width == 80 && rotatedImage.height == 120, "image rotation swaps width and height")
    let split = try FileTools.run(FileTools.split, files: [joined], engine: e) { _ in }
    let splitPages = split
    try require(splitPages.count == 2 && splitPages.allSatisfy { PDFDocument(url: $0)?.pageCount == 1 }, "PDF split writes one page per file")
    let merged = try FileTools.run(FileTools.merge, files: splitPages, engine: e) { _ in }
    try require(PDFDocument(url: merged[0])?.pageCount == 2, "PDF merge retains page count")
    let wav = inputs.appendingPathComponent("tone.wav")
    var wave = Data()
    func appendLE<T: FixedWidthInteger>(_ number: T) { var value = number.littleEndian; withUnsafeBytes(of: &value) { wave.append(contentsOf: $0) } }
    let sampleRate = 44100, samples = 22050
    wave.append(Data("RIFF".utf8)); appendLE(UInt32(36 + samples*2)); wave.append(Data("WAVEfmt ".utf8)); appendLE(UInt32(16)); appendLE(UInt16(1)); appendLE(UInt16(1)); appendLE(UInt32(sampleRate)); appendLE(UInt32(sampleRate*2)); appendLE(UInt16(2)); appendLE(UInt16(16)); wave.append(Data("data".utf8)); appendLE(UInt32(samples*2))
    for sample in 0..<samples { appendLE(Int16(sin(Double(sample)*440*2*Double.pi/Double(sampleRate))*10000)) }
    try wave.write(to: wav)
    let m4a = try e.convert(wav, to: "m4a"), aiff = try e.convert(m4a, to: "aiff"), wavAgain = try e.convert(aiff, to: "wav")
    let waveAgain = try Data(contentsOf: wavAgain)
    try require(String(data: waveAgain.prefix(4), encoding: .ascii) == "RIFF" && waveAgain.count > 1000, "WAV → AAC/M4A → AIFF → WAV yields valid audio")
    try require(WheelGeometry.selection(at: CGPoint(x: 166, y: 45), count: 6) == 0, "drop at top selects the top sector")
    try require(WheelGeometry.selection(at: CGPoint(x: 166, y: 166), count: 6) == nil, "drop in center does not start an accidental conversion")
    try require(WheelGeometry.selection(at: CGPoint(x: 330, y: 330), count: 6) == nil, "drop outside ring is rejected")
    let linkFiles = [URL(fileURLWithPath: "/tmp/кириллица ' $() & #?.png"), URL(fileURLWithPath: "/tmp/two words.pdf")]
    let selectionLink = SelectionLink.make(linkFiles)!
    try require(SelectionLink.files(from: [selectionLink]) == linkFiles, "Finder selection links preserve Unicode and reserved URL characters")
    try require(SelectionLink.files(from: [URL(string: "https://example.com/?file=file:///tmp/test")!]).isEmpty, "selection links reject unrelated URL schemes")
    try require(SelectionLink.files(from: [URL(string: "orbit-convert://selection?file=https%3A%2F%2Fexample.com")!]).isEmpty, "selection links reject non-file payloads")
    try require(SelectionLink.make([]) == nil && SelectionLink.make([URL(string: "https://example.com")!]) == nil, "Finder selection must contain local file URLs")
    // Use actual NSButton hit testing and dispatch; no window-level click interception.
    _ = NSApplication.shared
    let pointerWindow = OrbitPanel(contentRect: NSRect(x: 0, y: 0, width: 332, height: 332), styleMask: .borderless, backing: .buffered, defer: false)
    pointerWindow.isReleasedWhenClosed = false
    let pointer = WheelInputView(frame: NSRect(x: 0, y: 0, width: 332, height: 332))
    pointerWindow.contentView = pointer
    var clicked: String?
    pointer.onSelect = { clicked = $0.id }
    func clickWindow(_ window: NSWindow, at point: NSPoint, secondary: Bool = false, releaseAt: NSPoint? = nil) {
        let down = NSEvent.mouseEvent(with: secondary ? .rightMouseDown : .leftMouseDown, location: point, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber, context: nil, eventNumber: 1, clickCount: 1, pressure: 1)!
        let up = NSEvent.mouseEvent(with: secondary ? .rightMouseUp : .leftMouseUp, location: releaseAt ?? point, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime + 0.02, windowNumber: window.windowNumber, context: nil, eventNumber: 2, clickCount: 1, pressure: 0)!
        if secondary { NSApp.sendEvent(down); NSApp.sendEvent(up) }
        else {
            // NSButton tracks the mouse synchronously, consuming the queued release.
            NSApp.postEvent(up, atStart: true); NSApp.sendEvent(down)
        }
    }
    for count in [1, 3, 4, 6, 7, 10] {
        pointer.options = (0..<count).map { Format(id: "sector.\($0)", title: "\($0)", subtitle: "Test sector", icon: "circle") }
        for index in 0..<count {
            let angle = Double(index) * 2 * Double.pi / Double(count) - Double.pi / 2
            let point = CGPoint(x: 166 + cos(angle) * 117, y: 166 + sin(angle) * 117)
            let hit = pointer.hitTest(pointer.convert(point, to: pointer.superview)) as? WheelSectorButton
            try require(hit === pointer.sectorButtons[index], "native hit test selects sector \(index) of \(count)")
            clicked = nil; _ = hit?.accessibilityPerformPress()
            try require(clicked == "sector.\(index)", "native button action selects sector \(index) of \(count)")
        }
        if count > 1 {
            let angle = Double.pi / Double(count) - Double.pi / 2
            let point = CGPoint(x: 166 + cos(angle) * 117, y: 166 + sin(angle) * 117)
            try require(pointer.hitTest(pointer.convert(point, to: pointer.superview)) == nil, "visible sector gaps reject input for \(count) sectors")
        }
    }
    pointer.options = FileActions.all
    clicked = nil; _ = pointer.sectorButtons[1].accessibilityPerformPress()
    try require(clicked == "action.shelf", "native Shelf button executes Shelf")
    try require(pointer.hitTest(pointer.convert(CGPoint(x: 166, y: 166), to: pointer.superview)) == nil, "center is not a sector button")
    pointerWindow.orderBack(nil)
    let terminalPoint = pointer.convert(NSPoint(x: 65, y: 107), to: nil)
    let shelfPoint = pointer.convert(NSPoint(x: 267, y: 107), to: nil)
    clicked = nil
    clickWindow(pointerWindow, at: terminalPoint, releaseAt: shelfPoint)
    try require(clicked == nil, "releasing in another sector cancels the native button press")
    pointerWindow.orderOut(nil)
    let centralFolder = root.appendingPathComponent("new-downloads/Orbit", isDirectory: true)
    try require(!fm.fileExists(atPath: centralFolder.path), "output folder does not need to exist before conversion")
    let adjacent = try ConversionEngine(outputDirectory: centralFolder).convert(source, to: "jpg")
    try require(adjacent.deletingLastPathComponent() == centralFolder && fm.fileExists(atPath: adjacent.path), "conversion creates the Orbit destination and saves inside it")
    let downloads = fm.urls(for: .downloadsDirectory, in: .userDomainMask).first!
    try require(ConversionEngine().outputDirectory == downloads.appendingPathComponent("Orbit", isDirectory: true), "default destination is Downloads/Orbit")
    let singlePDF = try e.imagesToPDF([source]) { _ in }
    let singleJPG = try e.convertFiles(singlePDF, to: "jpg")
    try require(singleJPG.count == 1 && singleJPG[0].pathExtension == "jpg" && singleJPG[0].deletingLastPathComponent().path == outputs.path, "single-page PDF produces a standalone JPG rather than a folder")
    try require(CGImageSourceCreateWithURL(singleJPG[0] as CFURL, nil).flatMap { CGImageSourceCreateImageAtIndex($0, 0, nil) } != nil, "single-page PDF output is a decodable image")
    let pageImages = try e.convertFiles(joined, to: "jpg")
    try require(pageImages.count == 2 && pageImages.allSatisfy { $0.pathExtension == "jpg" && (try? $0.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true }, "multi-page PDF delivers regular JPG files, without a folder or ZIP")
    try require(pageImages.map(\.lastPathComponent) == ["Страница 001.jpg", "Страница 002.jpg"], "PDF page files retain page order")
    let htmlResult = try e.convertFiles(rtfd, to: "html")
    try require(htmlResult.count == 1 && (try htmlResult[0].resourceValues(forKeys: [.isDirectoryKey])).isDirectory == true, "HTML keeps its required image assets package")
    let board = NSPasteboard.withUniqueName()
    defer { board.releaseGlobally() }
    var revealed: [[URL]] = []
    let delivery = ResultDelivery(pasteboard: board, showInFinder: { revealed.append($0) })
    board.setString("keep clipboard", forType: .string)
    try require(!delivery.copy([]) && board.string(forType: .string) == "keep clipboard", "no results preserves clipboard")
    try require(!delivery.copy([inputs.appendingPathComponent("missing-result.jpg")]) && board.string(forType: .string) == "keep clipboard", "missing result preserves clipboard")
    try require(delivery.copy([adjacent]), "converted file can be copied as a file URL")
    let copied = board.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL]
    try require(copied == [adjacent], "clipboard contains the result file, not path text")
    try require(delivery.copy(pageImages), "PDF page images can be copied together")
    try require((board.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL]) == pageImages, "clipboard contains each JPG rather than the page folder")
    let domain = "dev.ybivashhka.orbit.tests." + UUID().uuidString
    let prefs = UserDefaults(suiteName: domain)!
    defer { prefs.removePersistentDomain(forName: domain) }
    let model = OrbitModel(defaults: prefs, delivery: delivery, outputDirectory: centralFolder)
    var closed = 0
    model.close = { closed += 1 }
    func finish(_ model: OrbitModel) throws {
        let deadline = Date().addingTimeInterval(20)
        while model.phase != .done && Date() < deadline { RunLoop.current.run(until: Date().addingTimeInterval(0.01)) }
        try require(model.phase == .done, "conversion completes through the model")
    }
    var completion: ConversionFeedback?
    model.didComplete = { completion = $0 }
    model.prepare([source]); model.start(.jpg); try finish(model)
    try require(model.results.count == 1 && model.results[0].deletingLastPathComponent() == centralFolder, "app model saves results in the Orbit destination")
    try require(model.copiedResults && (board.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL]) == model.results, "successful conversion automatically copies actual result")
    try require(revealed.last == model.results && closed == 1, "successful conversion closes wheel and selects results in Finder")
    try require(completion?.files == model.results && completion?.filename == model.results.first?.lastPathComponent && completion?.copied == true, "completion notice names the newly converted file and clipboard state")
    model.prepare([singlePDF]); model.start(.jpg); try finish(model)
    try require(model.results.count == 1 && model.results[0].deletingLastPathComponent() == centralFolder && model.results[0].pathExtension == "jpg", "app exports a single-page PDF as a JPG in Orbit")
    try require((board.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL]) == model.results, "app copies the standalone JPG file")
    model.prepare([joined]); model.start(.png); try finish(model)
    try require(model.results.count == 2 && model.results.allSatisfy { $0.pathExtension == "png" }, "app returns every PDF page as an image")
    try require((board.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL]) == model.results, "app copies page image URLs instead of an archiveable folder")
    let revealCount = revealed.count
    board.clearContents(); board.setString("keep after failure", forType: .string)
    let badImage = inputs.appendingPathComponent("broken-click.png"); try Data("invalid image".utf8).write(to: badImage)
    model.prepare([badImage]); model.start(.jpg); try finish(model)
    try require(model.results.isEmpty && !model.failures.isEmpty && revealed.count == revealCount && board.string(forType: .string) == "keep after failure", "failed conversion neither reveals files nor replaces clipboard")
    prefs.set(false, forKey: "copyResults"); prefs.set(false, forKey: "showResultsInFinder")
    model.prepare([source]); model.start(.jpg); try finish(model)
    try require(!model.copiedResults && revealed.count == revealCount && board.string(forType: .string) == "keep after failure", "export preferences can disable automatic clipboard and Finder")
    // Send real AppKit-dispatched click events through the SwiftUI hosting tree.
    let hostedModel = OrbitModel(defaults: prefs, delivery: delivery, outputDirectory: centralFolder)
    hostedModel.prepare([source])
    let hostedWindow = OrbitPanel(contentRect: NSRect(x: 0, y: 0, width: 430, height: 460), styleMask: .borderless, backing: .buffered, defer: false)
    hostedWindow.isReleasedWhenClosed = false
    let host = NSHostingView(rootView: OrbitShell(model: hostedModel))
    hostedWindow.contentView = host; hostedWindow.orderBack(nil)
    host.layoutSubtreeIfNeeded()
    RunLoop.current.run(until: Date().addingTimeInterval(0.1))
    let topSector = host.convert(NSPoint(x: 215, y: 110), to: nil)
    clickWindow(hostedWindow, at: topSector)
    try finish(hostedModel)
    try require(hostedModel.selected?.id == "jpg" && hostedModel.results.count == 1, "click through SwiftUI hosting starts the pointed conversion")
    hostedWindow.orderOut(nil)
    let secondaryModel = OrbitModel(defaults: prefs, delivery: delivery, outputDirectory: centralFolder)
    secondaryModel.prepare([source])
    let secondaryWindow = OrbitPanel(contentRect: NSRect(x: 0, y: 0, width: 430, height: 460), styleMask: .borderless, backing: .buffered, defer: false)
    secondaryWindow.isReleasedWhenClosed = false
    let secondaryHost = NSHostingView(rootView: OrbitShell(model: secondaryModel))
    secondaryWindow.contentView = secondaryHost; secondaryWindow.orderBack(nil)
    secondaryHost.layoutSubtreeIfNeeded(); RunLoop.current.run(until: Date().addingTimeInterval(0.1))
    let secondaryPoint = secondaryHost.convert(NSPoint(x: 306, y: 150), to: nil)
    clickWindow(secondaryWindow, at: secondaryPoint, secondary: true)
    try finish(secondaryModel)
    try require(secondaryModel.selected?.id == "pdf" && secondaryModel.results.count == 1, "two-finger secondary click on PDF starts the selected conversion")
    secondaryWindow.orderOut(nil)
    let movie = inputs.appendingPathComponent("clip.mov")
    let writer = try AVAssetWriter(outputURL: movie, fileType: .mov)
    let video = AVAssetWriterInput(mediaType: .video, outputSettings: [AVVideoCodecKey: AVVideoCodecType.h264, AVVideoWidthKey: 64, AVVideoHeightKey: 64])
    let adaptor = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: video, sourcePixelBufferAttributes: [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32ARGB, kCVPixelBufferWidthKey as String: 64, kCVPixelBufferHeightKey as String: 64])
    writer.add(video); writer.startWriting(); writer.startSession(atSourceTime: .zero)
    for frame in 0..<12 {
        let deadline = Date().addingTimeInterval(10)
        while !video.isReadyForMoreMediaData && Date() < deadline { Thread.sleep(forTimeInterval: 0.01) }
        var pixel: CVPixelBuffer?
        CVPixelBufferCreate(kCFAllocatorDefault, 64, 64, kCVPixelFormatType_32ARGB, nil, &pixel)
        guard let pixel = pixel else { throw OrbitError("Could not create video fixture.") }
        CVPixelBufferLockBaseAddress(pixel, [])
        memset(CVPixelBufferGetBaseAddress(pixel), Int32(50 + frame * 10), CVPixelBufferGetDataSize(pixel))
        CVPixelBufferUnlockBaseAddress(pixel, [])
        guard adaptor.append(pixel, withPresentationTime: CMTime(value: Int64(frame), timescale: 12)) else { throw OrbitError(writer.error?.localizedDescription ?? "Could not write video fixture.") }
    }
    video.markAsFinished(); let movieDone = DispatchSemaphore(value: 0)
    writer.finishWriting { movieDone.signal() }
    guard movieDone.wait(timeout: .now() + 30) == .success && writer.status == .completed else { throw OrbitError(writer.error?.localizedDescription ?? "Video fixture timed out.") }
    let mp4 = try e.convert(movie, to: "mp4")
    let generator = AVAssetImageGenerator(asset: AVURLAsset(url: mp4))
    let frame = try generator.copyCGImage(at: .zero, actualTime: nil)
    try require(frame.width == 64 && frame.height == 64, "MOV → MP4 produces a video with a decodable frame")
    print("\n\(checks) checks passed. Fixtures: \(root.path)")
} catch { fputs(error.localizedDescription + "\n", stderr); exit(1) }

func longTextFixture() -> NSAttributedString {
    NSAttributedString(string: String(repeating: "A paragraph of text to check native PDF pagination.\n", count: 160), attributes: [.font: NSFont.systemFont(ofSize: 12), .foregroundColor: NSColor.black])
}
