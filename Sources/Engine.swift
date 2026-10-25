import AppKit
import PDFKit
import ImageIO
import UniformTypeIdentifiers
import CoreText

struct OrbitError: LocalizedError {
    let message: String
    var errorDescription: String? { message }
    init(_ message: String) { self.message = message }
}

enum FileKind: String { case image, pdf, document, audio, video, archive, subtitle, table, unsupported }

struct Format: Identifiable, Equatable {
    let id: String
    let title: String
    let subtitle: String
    let icon: String
    static let png = Format(id: "png", title: "PNG", subtitle: "Без потери качества", icon: "photo")
    static let jpg = Format(id: "jpg", title: "JPG", subtitle: "Компактное изображение", icon: "photo.fill")
    static let heic = Format(id: "heic", title: "HEIC", subtitle: "Формат Apple", icon: "camera.aperture")
    static let tiff = Format(id: "tiff", title: "TIFF", subtitle: "Для печати", icon: "square.stack.3d.up")
    static let pdf = Format(id: "pdf", title: "PDF", subtitle: "Готово к отправке", icon: "doc.richtext")
    static let txt = Format(id: "txt", title: "TXT", subtitle: "Извлечь текст", icon: "text.alignleft")
    static let docx = Format(id: "docx", title: "DOCX", subtitle: "Документ Word", icon: "doc.text")
    static let rtf = Format(id: "rtf", title: "RTF", subtitle: "Форматированный текст", icon: "textformat")
    static let html = Format(id: "html", title: "HTML", subtitle: "Веб-документ", icon: "chevron.left.forwardslash.chevron.right")
    static let bmp = Format(id: "bmp", title: "BMP", subtitle: "Растровое изображение BMP", icon: "photo")
    static let avif = Format(id: "avif", title: "AVIF", subtitle: "Компактное изображение AVIF", icon: "photo")
    static let gif = Format(id: "gif", title: "GIF", subtitle: "Один кадр GIF, без анимации", icon: "photo")
}

final class ConversionEngine {
    let fm = FileManager.default
    var quality: Double = 0.9
    var dpi: Double = 144
    var isCancelled: () -> Bool = { false }
    static var defaultOutputDirectory: URL {
        let downloads = FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask).first
            ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Downloads", isDirectory: true)
        return downloads.appendingPathComponent("Orbit", isDirectory: true)
    }
    let outputDirectory: URL
    init(outputDirectory: URL? = nil) { self.outputDirectory = outputDirectory ?? Self.defaultOutputDirectory }

    static func kind(_ url: URL) -> FileKind {
        let ext = url.pathExtension.lowercased()
        if let extra = ExtraConversions.kind(url) { return extra }
        if ext == "pdf" { return .pdf }
        if ["doc", "docx", "rtf", "rtfd", "txt", "html", "htm", "odt", "pages"].contains(ext) { return .document }
        if let source = CGImageSourceCreateWithURL(url as CFURL, nil), CGImageSourceGetCount(source) > 0 { return .image }
        return .unsupported
    }

    static var wordAvailable: Bool { FileManager.default.fileExists(atPath: "/Applications/Microsoft Word.app") }
    static var pagesAvailable: Bool { FileManager.default.fileExists(atPath: "/Applications/Pages.app") || FileManager.default.fileExists(atPath: NSHomeDirectory() + "/Applications/Pages.app") }
    static func imageType(_ ext: String) -> UTType? {
        // Explicit identifiers also work when LaunchServices is unavailable (CLI, tests).
        switch ext { case "png": return .png; case "jpg", "jpeg": return .jpeg; case "heic": return .heic; case "tiff", "tif": return .tiff; case "bmp": return UTType(importedAs: "com.microsoft.bmp"); case "avif": return UTType(importedAs: "public.avif"); case "gif": return .gif; default: return nil }
    }
    static func formats(for url: URL) -> [Format] {
        let ext = url.pathExtension.lowercased()
        switch kind(url) {
        case .image:
            let destinations = CGImageDestinationCopyTypeIdentifiers() as! [String]
            return [Format.png, .jpg, .pdf, .heic, .tiff, .avif, .bmp, .gif].filter { f in
                if f.id == "pdf" { return true }
                guard let type = imageType(f.id) else { return false }
                return destinations.contains(type.identifier)
            }.filter { !($0.id == ext || ($0.id == "jpg" && ext == "jpeg") || ($0.id == "tiff" && ext == "tif")) }
        case .pdf: return [.png, .jpg, .txt, .init(id: "docx", title: "DOCX · текст", subtitle: "Только текстовый слой; вёрстка PDF не сохраняется", icon: "doc.text")]
        case .document:
            if ext == "pages" { return pagesAvailable ? [.pdf, .docx] : [] }
            var result: [Format] = [.docx, .rtf, .txt, .html]
            let office = UserDefaults.standard.string(forKey: "pdfEngine") == "office" && (wordAvailable || pagesAvailable)
            result.insert(.init(id: "pdf", title: "PDF", subtitle: office ? "Экспорт через Word / Pages" : "Базовая вёрстка macOS; сложное оформление может измениться", icon: "doc.richtext"), at: 0)
            return result.filter { $0.id != ext }
        case .unsupported: return []
        default: return ExtraConversions.formats(url)
        }
    }
    static func commonFormats(_ urls: [URL]) -> [Format] {
        guard let first = urls.first else { return [] }
        return formats(for: first).filter { f in urls.dropFirst().allSatisfy { formats(for: $0).contains(f) } }
    }

    func check() throws { if isCancelled() { throw OrbitError("Конвертация отменена.") } }
    func unique(_ input: URL, ext: String, folder: Bool = false) throws -> URL {
        let parent = outputDirectory
        do { try fm.createDirectory(at: parent, withIntermediateDirectories: true) }
        catch { throw OrbitError("Не удалось создать папку «\(parent.path)»: \(error.localizedDescription)") }
        guard fm.isWritableFile(atPath: parent.path) else { throw OrbitError("Нет прав на запись в папку «\(parent.lastPathComponent)». Скопируйте файл в доступную папку.") }
        let stem = input.deletingPathExtension().lastPathComponent + (folder ? " — " + ext.uppercased() : "")
        for i in 0..<10000 {
            let name = stem + (i == 0 ? "" : " (\(i))")
            let candidate = folder ? parent.appendingPathComponent(name, isDirectory: true) : parent.appendingPathComponent(name).appendingPathExtension(ext)
            if candidate.standardizedFileURL != input.standardizedFileURL && !fm.fileExists(atPath: candidate.path) { return candidate }
        }
        throw OrbitError("Не удалось подобрать свободное имя файла.")
    }
    func write(_ data: Data, to url: URL) throws {
        guard !data.isEmpty else { throw OrbitError("Конвертер вернул пустой файл.") }
        try data.write(to: url, options: .withoutOverwriting)
    }
    func image(_ input: URL) throws -> CGImage {
        guard let source = CGImageSourceCreateWithURL(input as CFURL, nil) else { throw OrbitError("Не удалось прочитать изображение.") }
        let props = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any] ?? [:]
        let w = props[kCGImagePropertyPixelWidth] as? Int ?? 0
        let h = props[kCGImagePropertyPixelHeight] as? Int ?? 0
        guard w > 0, h > 0, Double(w) * Double(h) <= 120_000_000 else { throw OrbitError("Изображение слишком большое или повреждено (лимит — 120 Мп).") }
        let options: [CFString: Any] = [kCGImageSourceCreateThumbnailFromImageAlways: true, kCGImageSourceCreateThumbnailWithTransform: true, kCGImageSourceThumbnailMaxPixelSize: max(w, h)]
        guard let image = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else { throw OrbitError("Не удалось декодировать изображение.") }
        return image
    }
    func imageData(_ cgImage: CGImage, ext: String) throws -> Data {
        guard let type = Self.imageType(ext) else { throw OrbitError("Неизвестный формат.") }
        var image = cgImage
        if ext == "jpg" {
            guard let ctx = CGContext(data: nil, width: image.width, height: image.height, bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue) else { throw OrbitError("Недостаточно памяти.") }
            ctx.setFillColor(CGColor.white); ctx.fill(CGRect(x: 0, y: 0, width: image.width, height: image.height))
            ctx.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
            guard let opaque = ctx.makeImage() else { throw OrbitError("Не удалось подготовить JPG.") }; image = opaque
        }
        let data = NSMutableData()
        guard let dest = CGImageDestinationCreateWithData(data, type.identifier as CFString, 1, nil) else { throw OrbitError("Этот Mac не поддерживает экспорт \(ext.uppercased()).") }
        CGImageDestinationAddImage(dest, image, [kCGImageDestinationLossyCompressionQuality: quality] as CFDictionary)
        guard CGImageDestinationFinalize(dest) else { throw OrbitError("Не удалось записать \(ext.uppercased()).") }
        return data as Data
    }
    func convert(_ input: URL, to format: String, progress: (Double) -> Void = { _ in }) throws -> URL {
        try check()
        guard Self.formats(for: input).contains(where: { $0.id == format }) else { throw OrbitError("Преобразование \(input.pathExtension.uppercased()) → \(format.uppercased()) недоступно.") }
        switch Self.kind(input) {
        case .image:
            if format == "pdf" { return try imagesToPDF([input], progress: progress) }
            let output = try unique(input, ext: format)
            try write(imageData(image(input), ext: format), to: output)
            progress(1); return output
        case .pdf: return try convertPDF(input, to: format, progress: progress)
        case .document: return try convertDocument(input, to: format)
        case .unsupported: throw OrbitError("Тип файла пока не поддерживается.")
        default: return try ExtraConversions.convert(input, to: format, engine: self, progress: progress)
        }
    }
    /// PDF page sets are delivered as image files, never as a folder to paste.
    /// HTML packages and intentional archives retain their original container.
    func convertFiles(_ input: URL, to format: String, progress: (Double) -> Void = { _ in }) throws -> [URL] {
        let output = try convert(input, to: format, progress: progress)
        guard input.pathExtension.lowercased() == "pdf", ["png", "jpg"].contains(format),
              (try output.resourceValues(forKeys: [.isDirectoryKey])).isDirectory == true else { return [output] }
        return try fm.contentsOfDirectory(at: output, includingPropertiesForKeys: [.isRegularFileKey])
            .filter { $0.pathExtension.lowercased() == format && (try? $0.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true }
            .sorted { $0.lastPathComponent < $1.lastPathComponent }
    }
    func imagesToPDF(_ inputs: [URL], progress: (Double) -> Void) throws -> URL {
        guard let first = inputs.first else { throw OrbitError("Нет файлов.") }
        let output = try unique(first, ext: "pdf")
        let data = NSMutableData()
        guard let consumer = CGDataConsumer(data: data), let ctx = CGContext(consumer: consumer, mediaBox: nil, nil) else { throw OrbitError("Не удалось создать PDF.") }
        for (i, input) in inputs.enumerated() {
            try check()
            try autoreleasepool {
                let cg = try image(input)
                let scale = min(1, 1440 / Double(max(cg.width, cg.height)))
                let rect = CGRect(x: 0, y: 0, width: Double(cg.width) * scale, height: Double(cg.height) * scale)
                ctx.beginPDFPage([kCGPDFContextMediaBox as String: NSData(bytes: [rect], length: MemoryLayout<CGRect>.size)] as CFDictionary)
                ctx.draw(cg, in: rect); ctx.endPDFPage()
            }
            progress(Double(i + 1) / Double(inputs.count))
        }
        ctx.closePDF(); try write(data as Data, to: output); return output
    }
    func convertPDF(_ input: URL, to format: String, progress: (Double) -> Void) throws -> URL {
        guard let pdf = PDFDocument(url: input), !pdf.isLocked, pdf.pageCount > 0 else { throw OrbitError("PDF повреждён или защищён паролем. Сначала откройте и разблокируйте его.") }
        if format == "txt" || format == "docx" {
            var parts: [String] = []
            for i in 0..<pdf.pageCount { try check(); parts.append(pdf.page(at: i)?.string ?? ""); progress(Double(i+1)/Double(pdf.pageCount)) }
            let text = parts.joined(separator: "\n\n")
            guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { throw OrbitError("В PDF нет текстового слоя. Для сканов нужно распознавание текста; эта версия его не выполняет.") }
            let output = try unique(input, ext: format)
            if format == "txt" { try write(Data(text.utf8), to: output) }
            else {
                try ExtraConversions.withTemporaryFolder(self) { temp in
                    let plain = temp.appendingPathComponent("text.txt"), generated = temp.appendingPathComponent("text.docx")
                    try Data(text.utf8).write(to: plain)
                    try process("/usr/bin/textutil", ["-noload", "-convert", "docx", "-output", generated.path, plain.path])
                    try fm.copyItem(at: generated, to: output)
                }
            }
            return output
        }
        guard pdf.pageCount <= 500 else { throw OrbitError("В PDF больше 500 страниц. Разделите его перед экспортом изображений.") }
        let multiple = pdf.pageCount > 1
        let output = try unique(input, ext: format, folder: multiple)
        if multiple { try fm.createDirectory(at: output, withIntermediateDirectories: false) }
        do {
            for i in 0..<pdf.pageCount {
                try check()
                try autoreleasepool {
                    guard let page = pdf.page(at: i), let ref = page.pageRef else { throw OrbitError("Не удалось прочитать страницу \(i+1).") }
                    var rect = page.bounds(for: .mediaBox)
                    if page.rotation % 180 != 0 { rect.size = CGSize(width: rect.height, height: rect.width) }
                    let w = Int(ceil(rect.width * dpi / 72)), h = Int(ceil(rect.height * dpi / 72))
                    guard w > 0, h > 0, Double(w)*Double(h) <= 120_000_000, let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { throw OrbitError("Страница слишком большая для экспорта.") }
                    let target = CGRect(x: 0, y: 0, width: w, height: h)
                    ctx.setFillColor(CGColor.white); ctx.fill(target)
                    ctx.concatenate(ref.getDrawingTransform(.mediaBox, rect: target, rotate: 0, preserveAspectRatio: true))
                    ctx.drawPDFPage(ref)
                    guard let cg = ctx.makeImage() else { throw OrbitError("Не удалось отрисовать страницу.") }
                    let pageFile = multiple ? output.appendingPathComponent(String(format: "Страница %03d.%@", i+1, format)) : output
                    try write(imageData(cg, ext: format), to: pageFile)
                }
                progress(Double(i+1)/Double(pdf.pageCount))
            }
        } catch { try? fm.removeItem(at: output); throw error }
        return output
    }
    @discardableResult
    func process(_ executable: String, _ arguments: [String], timeout: TimeInterval = 90) throws -> String {
        let p = Process(); p.executableURL = URL(fileURLWithPath: executable); p.arguments = arguments
        // Files avoid pipe-buffer deadlocks and concurrent mutation of captured Data.
        let logDirectory = fm.temporaryDirectory.appendingPathComponent("orbit-process-" + UUID().uuidString)
        try fm.createDirectory(at: logDirectory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        defer { try? fm.removeItem(at: logDirectory) }
        let outURL = logDirectory.appendingPathComponent("out"), errURL = logDirectory.appendingPathComponent("err")
        fm.createFile(atPath: outURL.path, contents: nil, attributes: [.posixPermissions: 0o600])
        fm.createFile(atPath: errURL.path, contents: nil, attributes: [.posixPermissions: 0o600])
        let stdout = try FileHandle(forWritingTo: outURL), stderr = try FileHandle(forWritingTo: errURL)
        defer { try? stdout.close(); try? stderr.close() }
        p.standardOutput = stdout; p.standardError = stderr
        try p.run(); let deadline = Date().addingTimeInterval(timeout)
        while p.isRunning {
            if isCancelled() || Date() > deadline { p.terminate(); p.waitUntilExit(); throw OrbitError(isCancelled() ? "Конвертация отменена." : "Приложение не ответило за 90 секунд. Проверьте, нет ли в Word или Pages диалога.") }
            Thread.sleep(forTimeInterval: 0.05)
        }
        p.waitUntilExit()
        let out = (try? Data(contentsOf: outURL)) ?? Data(), err = (try? Data(contentsOf: errURL)) ?? Data()
        guard p.terminationStatus == 0 else {
            let detail = String(data: err, encoding: .utf8) ?? "Неизвестная ошибка"
            if detail.contains("1743") || detail.contains("not authorized") { throw OrbitError("Разрешите Orbit управлять Word или Pages: Настройки системы → Конфиденциальность и безопасность → Автоматизация.") }
            throw OrbitError(String(detail.prefix(600)))
        }
        return String(data: out, encoding: .utf8) ?? ""
    }
    func convertDocument(_ input: URL, to format: String) throws -> URL {
        let output = try unique(input, ext: format, folder: format == "html")
        if format == "pdf" || input.pathExtension.lowercased() == "pages" {
            if input.pathExtension.lowercased() == "pages" || (UserDefaults.standard.string(forKey: "pdfEngine") == "office" && !Self.wordAvailable && Self.pagesAvailable) {
                try officeExport(input, output, app: "Pages", format: format)
            } else if Self.wordAvailable && UserDefaults.standard.string(forKey: "pdfEngine") == "office" {
                try officeExport(input, output, app: "Microsoft Word", format: format)
            } else {
                try ExtraConversions.withTemporaryFolder(self) { temp in
                    let rich = temp.appendingPathComponent("document.rtfd")
                    try process("/usr/bin/textutil", ["-noload", "-convert", "rtfd", "-output", rich.path, input.path])
                    let text = try NSMutableAttributedString(url: rich, options: [.documentType: NSAttributedString.DocumentType.rtfd], documentAttributes: nil)
                    if input.pathExtension.lowercased() == "txt" { text.addAttributes([.font: NSFont.systemFont(ofSize: 12), .foregroundColor: NSColor.black], range: NSRange(location: 0, length: text.length)) }
                    try write(richTextPDF(text), to: output)
                }
            }
        } else {
            // Run in a private temporary directory; publish only a complete result.
            let temp = fm.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
            try fm.createDirectory(at: temp, withIntermediateDirectories: true); defer { try? fm.removeItem(at: temp) }
            let generated = temp.appendingPathComponent((format == "html" ? "index." : "converted.") + format)
            try process("/usr/bin/textutil", ["-noload", "-convert", format, "-output", generated.path, input.path])
            if format == "html" { try fm.copyItem(at: temp, to: output) }
            else { try write(Data(contentsOf: generated), to: output) }
        }
        let validate = format == "html" ? output.appendingPathComponent("index.html") : output
        guard fm.fileExists(atPath: validate.path), (try? validate.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0 > 0 else { throw OrbitError("Конвертер не создал результат.") }
        return output
    }
    func officeExport(_ input: URL, _ output: URL, app: String, format: String) throws {
        // A stable, dedicated workspace lets sandboxed Word remember its folder
        // permission. All temporary documents have unpredictable unique names.
        let temp = fm.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("Orbit/OfficeWorkspace", isDirectory: true)
        try fm.createDirectory(at: temp, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let identifier = "Orbit-" + UUID().uuidString
        let source = temp.appendingPathComponent(identifier + "." + input.pathExtension)
        let generated = temp.appendingPathComponent(identifier + "-export." + format)
        defer { try? fm.removeItem(at: source); try? fm.removeItem(at: generated) }
        try fm.copyItem(at: input, to: source)
        // Arguments carry paths as data. Never interpolate file names into AppleScript.
        let script: String
        if app == "Pages" {
            script = """
            on run argv
              set inputFile to POSIX file (item 1 of argv)
              set outputFile to POSIX file (item 2 of argv)
              tell application "Pages"
                with timeout of 85 seconds
                  set d to open inputFile
                  try
                    export d to outputFile as \(format == "pdf" ? "PDF" : "Microsoft Word")
                  on error msg number num
                    close d saving no
                    error msg number num
                  end try
                  close d saving no
                end timeout
              end tell
            end run
            """
        } else {
            script = """
            on run argv
              set inputPath to item 1 of argv
              set inputFile to (POSIX file inputPath) as alias
              set outputPath to item 2 of argv
              set expectedName to item 3 of argv
              tell application "Microsoft Word"
                with timeout of 85 seconds
                  open inputFile read only true add to recent files false
                  set d to missing value
                  set lastProblem to ""
                  repeat 40 times
                    try
                      if (name of active document) is expectedName then
                        set d to document expectedName
                        exit repeat
                      end if
                    on error msg
                      set lastProblem to msg
                    end try
                    delay 0.1
                  end repeat
                  if d is missing value then error "Word не открыл копию документа. " & lastProblem
                  set ownWindow to get active window
                  try
                    save as d file name outputPath file format format PDF
                  on error msg number num
                    try
                      close ownWindow saving no
                    end try
                    error msg number num
                  end try
                  try
                    close ownWindow saving no
                  end try
                end timeout
              end tell
            end run
            """
        }
        try process("/usr/bin/osascript", ["-e", script, source.path, generated.path, source.lastPathComponent])
        guard let data = try? Data(contentsOf: generated), !data.isEmpty else { throw OrbitError("\(app) не создал файл. Проверьте, что приложение активировано и документ открывается.") }
        if format == "pdf", PDFDocument(data: data) == nil { throw OrbitError("\(app) вернул некорректный PDF.") }
        try write(data, to: output)
    }
    func textPDF(_ text: NSAttributedString) throws -> Data {
        guard text.length > 0 else { throw OrbitError("Документ пуст.") }
        let data = NSMutableData(); var box = CGRect(x: 0, y: 0, width: 595.28, height: 841.89)
        guard let consumer = CGDataConsumer(data: data), let ctx = CGContext(consumer: consumer, mediaBox: &box, nil) else { throw OrbitError("Не удалось создать PDF.") }
        let setter = CTFramesetterCreateWithAttributedString(text)
        let path = CGPath(rect: box.insetBy(dx: 48, dy: 48), transform: nil)
        var offset = 0
        while offset < text.length {
            try check(); ctx.beginPDFPage(nil)
            let frame = CTFramesetterCreateFrame(setter, CFRange(location: offset, length: 0), path, nil)
            let visible = CTFrameGetVisibleStringRange(frame)
            guard visible.length > 0 else { throw OrbitError("Не удалось разместить текст на странице.") }
            CTFrameDraw(frame, ctx); ctx.endPDFPage(); offset += visible.length
        }
        ctx.closePDF(); return data as Data
    }
    func richTextPDF(_ original: NSAttributedString) throws -> Data {
        guard original.length > 0 else { throw OrbitError("Документ пуст.") }
        let storage = NSTextStorage(attributedString: original)
        storage.enumerateAttribute(.font, in: NSRange(location: 0, length: storage.length)) { value, range, _ in if value == nil { storage.addAttribute(.font, value: NSFont.systemFont(ofSize: 12), range: range) } }
        storage.enumerateAttribute(.foregroundColor, in: NSRange(location: 0, length: storage.length)) { value, range, _ in if value == nil { storage.addAttribute(.foregroundColor, value: NSColor.black, range: range) } }
        let layout = NSLayoutManager(); storage.addLayoutManager(layout)
        var pages: [(NSTextContainer, NSRange)] = []
        while pages.count < 1000 {
            try check()
            let container = NSTextContainer(size: CGSize(width: 499.28, height: 745.89)); container.lineFragmentPadding = 0
            layout.addTextContainer(container); layout.ensureLayout(for: container)
            let range = layout.glyphRange(for: container)
            guard range.length > 0 else { break }
            pages.append((container, range))
            if NSMaxRange(range) >= layout.numberOfGlyphs { break }
        }
        guard let last = pages.last, NSMaxRange(last.1) >= layout.numberOfGlyphs else { throw OrbitError("Не удалось разместить документ: слишком большой блок или больше 1000 страниц.") }
        let data = NSMutableData(); var box = CGRect(x: 0, y: 0, width: 595.28, height: 841.89)
        guard let consumer = CGDataConsumer(data: data), let context = CGContext(consumer: consumer, mediaBox: &box, nil) else { throw OrbitError("Не удалось создать PDF.") }
        for (_, range) in pages {
            try check(); context.beginPDFPage(nil)
            context.setFillColor(CGColor.white); context.fill(box)
            context.saveGState(); context.translateBy(x: 48, y: 841.89 - 48); context.scaleBy(x: 1, y: -1)
            NSGraphicsContext.saveGraphicsState(); NSGraphicsContext.current = NSGraphicsContext(cgContext: context, flipped: true)
            layout.drawBackground(forGlyphRange: range, at: .zero); layout.drawGlyphs(forGlyphRange: range, at: .zero)
            NSGraphicsContext.restoreGraphicsState(); context.restoreGState(); context.endPDFPage()
        }
        context.closePDF(); return data as Data
    }
}
