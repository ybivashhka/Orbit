import AppKit
import PDFKit
import SwiftUI

enum FileTools {
    static let compress = Format(id: "tool.compress", title: "Сжать", subtitle: "JPG, качество 75%; прозрачность заменяется белым", icon: "arrow.down.right.and.arrow.up.left")
    static let resize = Format(id: "tool.resize", title: "1600 px", subtitle: "Уменьшить длинную сторону до 1600 пикселей", icon: "arrow.up.left.and.arrow.down.right")
    static let rotate = Format(id: "tool.rotate", title: "Повернуть", subtitle: "Повернуть влево на 90°", icon: "rotate.left")
    static let mirror = Format(id: "tool.mirror", title: "Отразить", subtitle: "Отразить изображение по горизонтали", icon: "arrow.left.and.right.righttriangle.left.righttriangle.right")
    static let clean = Format(id: "tool.clean", title: "Метаданные", subtitle: "Пересоздать изображение без исходных EXIF; сохраняется новая копия", icon: "eye.slash")
    static let split = Format(id: "tool.split", title: "Разделить", subtitle: "Каждая страница в отдельный PDF", icon: "square.split.2x2")
    static let merge = Format(id: "tool.merge", title: "Объединить", subtitle: "Объединить выбранные PDF в порядке выбора", icon: "doc.on.doc")
    static let zip = Format(id: "tool.zip", title: "ZIP", subtitle: "Упаковать выбранные файлы в ZIP", icon: "archivebox")
    static func options(_ files: [URL]) -> [Format] {
        guard !files.isEmpty else { return [] }
        if files.allSatisfy({ ConversionEngine.kind($0) == .image }) { return [.init(id: compress.id, title: compress.title, subtitle: compress.subtitle, icon: compress.icon), resize, rotate, mirror, clean, zip] }
        if files.allSatisfy({ ConversionEngine.kind($0) == .pdf }) { return files.count > 1 ? [merge, split, rotate, zip] : [split, rotate, zip] }
        return [zip]
    }
    static func run(_ option: Format, files: [URL], engine: ConversionEngine, progress: (Double) -> Void) throws -> [URL] {
        guard let first = files.first else { throw OrbitError("Файлы не выбраны.") }
        if option.id == zip.id {
            let output = try engine.unique(first, ext: "zip")
            let temp = engine.fm.temporaryDirectory.appendingPathComponent("orbit-zip-" + UUID().uuidString)
            try engine.fm.createDirectory(at: temp, withIntermediateDirectories: true)
            defer { try? engine.fm.removeItem(at: temp) }
            let staged = temp.appendingPathComponent("files")
            try engine.fm.createDirectory(at: staged, withIntermediateDirectories: true)
            for (i, file) in files.enumerated() {
                try engine.check()
                var target = staged.appendingPathComponent(file.lastPathComponent)
                if engine.fm.fileExists(atPath: target.path) { target = staged.appendingPathComponent("\(i+1)-" + file.lastPathComponent) }
                try engine.fm.copyItem(at: file, to: target)
                progress(Double(i+1) / Double(files.count) * 0.5)
            }
            let archive = temp.appendingPathComponent("archive.zip")
            try engine.process("/usr/bin/ditto", ["-c", "-k", "--norsrc", staged.path, archive.path])
            try engine.fm.copyItem(at: archive, to: output); progress(1); return [output]
        }
        if option.id == merge.id {
            let doc = PDFDocument()
            for (i, file) in files.enumerated() {
                try engine.check()
                guard let source = PDFDocument(url: file), !source.isLocked, source.pageCount > 0 else { throw OrbitError("Не удалось открыть \(file.lastPathComponent).") }
                for index in 0..<source.pageCount { if let page = source.page(at: index)?.copy() as? PDFPage { doc.insert(page, at: doc.pageCount) } }
                progress(Double(i+1) / Double(files.count))
            }
            guard let data = doc.dataRepresentation() else { throw OrbitError("Не удалось объединить PDF.") }
            let output = try engine.unique(first, ext: "pdf"); try engine.write(data, to: output); return [output]
        }
        var outputs: [URL] = []
        for (i, file) in files.enumerated() {
            try engine.check()
            if ConversionEngine.kind(file) == .pdf {
                guard let source = PDFDocument(url: file), !source.isLocked, source.pageCount > 0 else { throw OrbitError("Не удалось открыть PDF.") }
                if option.id == split.id {
                    let folder = try engine.unique(file, ext: "pdf", folder: true)
                    try engine.fm.createDirectory(at: folder, withIntermediateDirectories: false)
                    do {
                        for index in 0..<source.pageCount {
                            try engine.check(); let single = PDFDocument()
                            guard let page = source.page(at: index)?.copy() as? PDFPage else { throw OrbitError("Не удалось прочитать страницу.") }
                            single.insert(page, at: 0)
                            guard let data = single.dataRepresentation() else { throw OrbitError("Не удалось записать страницу.") }
                            try engine.write(data, to: folder.appendingPathComponent(String(format: "Страница %03d.pdf", index+1)))
                        }
                    } catch { try? engine.fm.removeItem(at: folder); throw error }
                    outputs += try engine.fm.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil)
                        .filter { $0.pathExtension == "pdf" }.sorted { $0.lastPathComponent < $1.lastPathComponent }
                } else {
                    for index in 0..<source.pageCount { source.page(at: index)?.rotation -= 90 }
                    guard let data = source.dataRepresentation() else { throw OrbitError("Не удалось повернуть PDF.") }
                    let output = try engine.unique(file, ext: "pdf"); try engine.write(data, to: output); outputs.append(output)
                }
            } else {
                let input = try engine.image(file)
                var result = input
                var ext = ["jpg", "jpeg"].contains(file.pathExtension.lowercased()) ? "jpg" : "png"
                if option.id == compress.id { ext = "jpg"; engine.quality = 0.75 }
                if [resize.id, rotate.id, mirror.id].contains(option.id) {
                    var w = input.width, h = input.height
                    if option.id == rotate.id { swap(&w, &h) }
                    if option.id == resize.id {
                        let ratio = min(1, 1600.0 / Double(max(w,h))); w = max(1, Int(Double(w)*ratio)); h = max(1, Int(Double(h)*ratio))
                    }
                    guard let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { throw OrbitError("Недостаточно памяти.") }
                    ctx.interpolationQuality = .high
                    if option.id == rotate.id { ctx.translateBy(x: 0, y: CGFloat(h)); ctx.rotate(by: -.pi / 2); ctx.draw(input, in: CGRect(x: 0, y: 0, width: input.width, height: input.height)) }
                    else if option.id == mirror.id { ctx.translateBy(x: CGFloat(w), y: 0); ctx.scaleBy(x: -1, y: 1); ctx.draw(input, in: CGRect(x: 0, y: 0, width: w, height: h)) }
                    else { ctx.draw(input, in: CGRect(x: 0, y: 0, width: w, height: h)) }
                    guard let rendered = ctx.makeImage() else { throw OrbitError("Не удалось обработать изображение.") }; result = rendered
                }
                let output = try engine.unique(file, ext: ext)
                try engine.write(engine.imageData(result, ext: ext), to: output); outputs.append(output)
            }
            progress(Double(i+1) / Double(files.count))
        }
        return outputs
    }
}

enum FileActions {
    static let all: [Format] = [
        .init(id: "action.airdrop", title: "AirDrop", subtitle: "Открыть выбор получателя AirDrop", icon: "airplayaudio"),
        .init(id: "action.shelf", title: "Полка", subtitle: "Оставить файлы в плавающем окне", icon: "rectangle.on.rectangle"),
        .init(id: "action.copy", title: "Копировать", subtitle: "Скопировать файлы в буфер обмена", icon: "doc.on.doc"),
        .init(id: "action.move", title: "Переместить", subtitle: "Выбрать папку и переместить оригиналы", icon: "folder.badge.arrow.down"),
        .init(id: "action.path", title: "Путь", subtitle: "Скопировать полные пути к файлам", icon: "link"),
        .init(id: "action.terminal", title: "Терминал", subtitle: "Открыть содержащую папку в Terminal", icon: "terminal")
    ]
    static func perform(_ action: Format, files: [URL]) throws -> String {
        switch action.id {
        case "action.copy":
            NSPasteboard.general.clearContents(); NSPasteboard.general.writeObjects(files as [NSURL]); return "Файлы скопированы"
        case "action.path":
            NSPasteboard.general.clearContents(); NSPasteboard.general.setString(files.map(\.path).joined(separator: "\n"), forType: .string); return "Пути скопированы"
        case "action.airdrop":
            NSApp.activate(ignoringOtherApps: true)
            guard let service = NSSharingService(named: .sendViaAirDrop), service.canPerform(withItems: files) else { throw OrbitError("AirDrop сейчас недоступен на этом Mac.") }
            service.perform(withItems: files); return "Выберите получателя AirDrop"
        case "action.shelf": NSApp.activate(ignoringOtherApps: true); ShelfController.shared.show(files); return "Файлы на полке"
        case "action.terminal":
            guard let first = files.first else { throw OrbitError("Нет файлов.") }
            var directory: ObjCBool = false
            FileManager.default.fileExists(atPath: first.path, isDirectory: &directory)
            let folder = directory.boolValue ? first : first.deletingLastPathComponent()
            guard let terminal = NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.apple.Terminal") else { throw OrbitError("Terminal не найден.") }
            NSWorkspace.shared.open([folder], withApplicationAt: terminal, configuration: NSWorkspace.OpenConfiguration(), completionHandler: nil); return "Папка открыта в Terminal"
        case "action.move":
            NSApp.activate(ignoringOtherApps: true)
            let panel = NSOpenPanel(); panel.canChooseDirectories = true; panel.canChooseFiles = false; panel.canCreateDirectories = true
            panel.title = "Куда переместить файлы?"; panel.prompt = "Переместить"
            guard panel.runModal() == .OK, let folder = panel.url else { throw OrbitError("Перемещение отменено.") }
            var moved = 0
            for file in files {
                var target = folder.appendingPathComponent(file.lastPathComponent)
                if target.standardizedFileURL == file.standardizedFileURL { continue }
                var suffix = 1
                while FileManager.default.fileExists(atPath: target.path) {
                    target = folder.appendingPathComponent(file.deletingPathExtension().lastPathComponent + " (\(suffix))")
                    if !file.pathExtension.isEmpty { target = target.appendingPathExtension(file.pathExtension) }
                    suffix += 1
                }
                do { try FileManager.default.moveItem(at: file, to: target); moved += 1 }
                catch { throw OrbitError("Перемещено: \(moved). Не удалось переместить \(file.lastPathComponent): \(error.localizedDescription)") }
            }
            return "Перемещено файлов: \(moved)"
        default: throw OrbitError("Неизвестное действие.")
        }
    }
}

final class ShelfModel: ObservableObject { @Published var files: [URL] = [] }
struct ShelfView: View {
    @ObservedObject var model: ShelfModel
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack { OrbitMark(size: 21); Text("Полка Orbit").font(.system(size: 17, weight: .medium)); Spacer() }
            Text("Перетащите файл отсюда в нужное приложение").font(.system(size: 11)).foregroundStyle(orbitMuted)
            ScrollView {
                VStack(spacing: 7) {
                    ForEach(model.files, id: \.self) { file in
                        HStack(spacing: 10) {
                            Image(nsImage: NSWorkspace.shared.icon(forFile: file.path)).resizable().frame(width: 30, height: 30)
                            Text(file.lastPathComponent).font(.system(size: 12)).lineLimit(1).truncationMode(.middle)
                            Spacer()
                            Button { model.files.removeAll { $0 == file } } label: { Image(systemName: "xmark").font(.system(size: 9)).foregroundStyle(orbitMuted) }.buttonStyle(.plain)
                        }.padding(9).background(.white.opacity(0.04), in: RoundedRectangle(cornerRadius: 10))
                            .onDrag { NSItemProvider(object: file as NSURL) }
                    }
                }
            }
        }.padding(18).frame(width: 330, height: 300).background(DarkSurface()).preferredColorScheme(.dark)
    }
}
final class ShelfController {
    static let shared = ShelfController()
    let model = ShelfModel()
    var window: NSPanel?
    func show(_ files: [URL]) {
        for file in files where !model.files.contains(file) { model.files.append(file) }
        if window == nil {
            let panel = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 330, height: 300), styleMask: [.titled, .closable, .utilityWindow], backing: .buffered, defer: false)
            panel.title = "Полка Orbit"; panel.level = .floating; panel.hidesOnDeactivate = false; panel.isReleasedWhenClosed = false
            panel.contentView = NSHostingView(rootView: ShelfView(model: model)); panel.center(); window = panel
        }
        window?.makeKeyAndOrderFront(nil)
    }
}
