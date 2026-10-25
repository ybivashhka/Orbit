import AppKit
import SwiftUI
import UniformTypeIdentifiers
import ServiceManagement
import FinderSync

let orbitAccent = Color(red: 0.72, green: 0.96, blue: 0.43)
let orbitMuted = Color.white.opacity(0.48)

struct ConversionRecord: Codable, Identifiable {
    var id = UUID()
    let date: Date
    let name: String
    let paths: [String]
    let format: String
}

final class Cancellation {
    private let lock = NSLock()
    private var value = false
    var cancelled: Bool { lock.lock(); defer { lock.unlock() }; return value }
    func cancel() { lock.lock(); value = true; lock.unlock() }
}

final class OrbitModel: ObservableObject {
    enum Phase { case choose, working, done }
    @Published var urls: [URL] = []
    @Published var formats: [Format] = []
    @Published var phase: Phase = .choose
    @Published var progress = 0.0
    @Published var detail = ""
    @Published var results: [URL] = []
    @Published var failures: [String] = []
    @Published var selected: Format?
    @Published var mode: WheelMode = .convert { didSet { if mode != oldValue { dragHover = nil } } }
    @Published var dragSession = false
    @Published var dragHover: Int?
    @Published var actionMessage: String?
    @Published var history: [ConversionRecord] = []
    @Published var installed = false
    @Published var copiedResults = false
    let defaults: UserDefaults
    var delivery: ResultDelivery
    let outputDirectory: URL
    var cancellation = Cancellation()
    var close: (() -> Void)?
    var choose: (() -> Void)?
    var didComplete: ((ConversionFeedback) -> Void)?
    init(defaults: UserDefaults = .standard, delivery: ResultDelivery = ResultDelivery(), outputDirectory: URL = ConversionEngine.defaultOutputDirectory) {
        self.defaults = defaults; self.delivery = delivery; self.outputDirectory = outputDirectory
        if let data = defaults.data(forKey: "history"), let records = try? JSONDecoder().decode([ConversionRecord].self, from: data) { history = records }
        refreshInstalled()
    }
    func refreshInstalled() { installed = FIFinderSyncController.isExtensionEnabled }
    var title: String { urls.count == 1 ? urls[0].lastPathComponent : "\(urls.count) файлов" }
    var typeLabel: String {
        let types = Set(urls.map { $0.pathExtension.uppercased() }).sorted().joined(separator: " · ")
        return types.isEmpty ? "ФАЙЛЫ" : types
    }
    var busy: Bool { phase == .working }
    var wheelOptions: [Format] {
        switch mode { case .convert: return formats; case .tools: return FileTools.options(urls); case .actions: return FileActions.all }
    }
    func perform(_ option: Format) {
        if option.id.hasPrefix("action.") {
            if ["action.airdrop", "action.move", "action.shelf", "action.terminal"].contains(option.id) { close?() }
            do { actionMessage = try FileActions.perform(option, files: urls); phase = .done }
            catch { failures = [error.localizedDescription]; phase = .done }
        } else { start(option) }
    }
    func prepare(_ files: [URL]) {
        guard !busy else { NSSound.beep(); return }
        urls = files; formats = ConversionEngine.commonFormats(files); phase = .choose
        progress = 0; results = []; copiedResults = false; failures = []; detail = ""; selected = nil; actionMessage = nil; dragSession = false; dragHover = nil; mode = .convert
    }
    func start(_ format: Format) {
        guard phase == .choose else { return }
        selected = format; phase = .working; cancellation = Cancellation()
        let files = urls, token = cancellation, destination = outputDirectory
        let quality = defaults.object(forKey: "quality") as? Double ?? 0.9
        let dpi = defaults.object(forKey: "dpi") as? Double ?? 144
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let engine = ConversionEngine(outputDirectory: destination); engine.quality = quality; engine.dpi = dpi
            engine.isCancelled = { token.cancelled }
            var outputs: [URL] = [], errors: [String] = []
            if format.id.hasPrefix("tool.") {
                if [FileTools.merge.id, FileTools.zip.id].contains(format.id) {
                    DispatchQueue.main.async { self?.detail = format.subtitle }
                    do { outputs = try FileTools.run(format, files: files, engine: engine) { p in DispatchQueue.main.async { self?.progress = p } } }
                    catch { errors.append(error.localizedDescription) }
                } else {
                    for (i, file) in files.enumerated() {
                        if token.cancelled { errors.append("Обработка отменена."); break }
                        DispatchQueue.main.async { self?.detail = file.lastPathComponent }
                        do { outputs += try FileTools.run(format, files: [file], engine: engine) { p in DispatchQueue.main.async { self?.progress = (Double(i)+p)/Double(files.count) } } }
                        catch { errors.append("\(file.lastPathComponent): \(error.localizedDescription)") }
                    }
                }
            } else if format.id == "pdf", files.count > 1, files.allSatisfy({ ConversionEngine.kind($0) == .image }) {
                DispatchQueue.main.async { self?.detail = "Собираем \(files.count) изображений в один PDF" }
                do { outputs.append(try engine.imagesToPDF(files) { p in DispatchQueue.main.async { self?.progress = p } }) }
                catch { errors.append(error.localizedDescription) }
            } else {
                for (i, input) in files.enumerated() {
                    if token.cancelled { errors.append("Оставшиеся файлы не обработаны: конвертация отменена."); break }
                    DispatchQueue.main.async { self?.detail = input.lastPathComponent }
                    do {
                        let converted = try autoreleasepool { try engine.convertFiles(input, to: format.id) { p in
                            DispatchQueue.main.async { self?.progress = (Double(i) + p) / Double(files.count) }
                        } }
                        outputs += converted
                    } catch { errors.append("\(input.lastPathComponent): \(error.localizedDescription)") }
                    DispatchQueue.main.async { self?.progress = Double(i+1) / Double(files.count) }
                }
            }
            DispatchQueue.main.async {
                guard let self = self else { return }
                self.results = outputs; self.failures = errors; self.phase = .done
                if !outputs.isEmpty {
                    self.history.insert(ConversionRecord(date: Date(), name: self.title, paths: outputs.map(\.path), format: format.title), at: 0)
                    self.history = Array(self.history.prefix(20)); self.saveHistory()
                    if self.defaults.object(forKey: "copyResults") as? Bool != false { self.copyResults() }
                    if self.defaults.object(forKey: "showResultsInFinder") as? Bool != false {
                        if errors.isEmpty { self.close?() }
                        self.reveal()
                    }
                    self.didComplete?(ConversionFeedback(title: errors.isEmpty ? "Готово" : "Частично готово", filename: outputs.count == 1 ? outputs[0].lastPathComponent : "Создано файлов: \(outputs.count)", copied: self.copiedResults, files: outputs))
                }
            }
        }
    }
    func saveHistory() { defaults.set(try? JSONEncoder().encode(history), forKey: "history") }
    func copyResults() { copiedResults = delivery.copy(results) }
    func reveal() { delivery.reveal(results) }
    var resultLocation: String {
        let parents = Set(results.map { $0.deletingLastPathComponent().path })
        return parents.count == 1 ? (parents.first! as NSString).abbreviatingWithTildeInPath : "В папках исходных файлов"
    }
    func retry() { prepare(urls) }
    func noFormatsMessage() -> String {
        if urls.contains(where: { $0.pathExtension.lowercased() == "pages" }) && !ConversionEngine.pagesAvailable { return "Для документов .pages установите Pages. Остальные форматы работают без него." }
        if urls.count > 1 { return "У этих файлов нет общего формата конвертации. Выберите файлы одного типа." }
        return "Поддерживаются изображения, PDF, DOCX, DOC, RTF, TXT, HTML и ODT. Выберите другой файл." 
    }
}

struct OrbitMark: View {
    var size: CGFloat = 40
    var body: some View {
        ZStack {
            Circle().stroke(orbitAccent.opacity(0.28), lineWidth: size * 0.04).frame(width: size * 0.78, height: size * 0.78)
            Ellipse().stroke(orbitAccent, lineWidth: size * 0.045).frame(width: size * 0.96, height: size * 0.40).rotationEffect(.degrees(-35))
            Circle().fill(orbitAccent).frame(width: size * 0.18, height: size * 0.18).offset(x: size * 0.3, y: -size * 0.23)
            Circle().fill(orbitAccent.opacity(0.9)).frame(width: size * 0.16, height: size * 0.16)
        }.frame(width: size, height: size)
    }
}

struct DarkSurface: View {
    var body: some View {
        ZStack {
            Color(red: 0.055, green: 0.065, blue: 0.075)
            RadialGradient(colors: [orbitAccent.opacity(0.10), .clear], center: .topTrailing, startRadius: 0, endRadius: 380)
        }
    }
}

struct FormatButton: View {
    let format: Format
    let subtitle: String
    let action: () -> Void
    @State var hovered = false
    var body: some View {
        Button(action: action) {
            VStack(spacing: 7) {
                Image(systemName: format.icon).font(.system(size: 22, weight: .light))
                Text(format.title).font(.system(size: 13, weight: .semibold, design: .rounded))
            }.foregroundStyle(hovered ? Color.black : Color.white.opacity(0.9))
                .frame(width: 82, height: 76)
                .background(hovered ? orbitAccent : Color.white.opacity(0.055), in: RoundedRectangle(cornerRadius: 22))
                .overlay(RoundedRectangle(cornerRadius: 22).stroke(hovered ? orbitAccent : .white.opacity(0.10), lineWidth: 1))
                .scaleEffect(hovered ? 1.07 : 1)
        }.buttonStyle(.plain).help(subtitle).onHover { hovered = $0 }
            .animation(.easeOut(duration: 0.14), value: hovered)
            .accessibilityLabel("Конвертировать в " + format.title)
    }
}

struct RadialView: View {
    @ObservedObject var model: OrbitModel
    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                OrbitMark(size: 20)
                Text("orbit").font(.system(size: 17, weight: .semibold, design: .rounded)).tracking(0.4)
                Spacer()
                if !model.busy { Button { model.close?() } label: { Image(systemName: "xmark").font(.system(size: 12, weight: .medium)).foregroundStyle(orbitMuted).frame(width: 28, height: 28).background(.white.opacity(0.05), in: Circle()) }.buttonStyle(.plain).help("Закрыть · Esc") }
            }.padding(.horizontal, 27).padding(.top, 23)
            if model.phase == .choose { chooser }
            else if model.phase == .working { working }
            else { completion }
        }
        .frame(width: 430, height: 460)
        .background(DarkSurface())
        .clipShape(RoundedRectangle(cornerRadius: 32))
        .overlay(RoundedRectangle(cornerRadius: 32).stroke(.white.opacity(0.13), lineWidth: 1))
        .preferredColorScheme(.dark)
    }
    var chooser: some View {
        VStack(spacing: 0) {
            if model.formats.isEmpty {
                Spacer()
                Image(systemName: "doc.badge.ellipsis").font(.system(size: 48, weight: .ultraLight)).foregroundStyle(orbitAccent)
                Text("Выберите другой файл").font(.system(size: 21, weight: .medium)).padding(.top, 20)
                Text(model.noFormatsMessage()).font(.system(size: 13)).foregroundStyle(orbitMuted).multilineTextAlignment(.center).padding(.horizontal, 40).padding(.top, 10)
                Spacer()
                Button("Выбрать файлы") { model.close?(); model.choose?() }.buttonStyle(.borderedProminent).tint(orbitAccent).foregroundStyle(.black)
                Spacer().frame(height: 35)
            } else {
                ZStack {
                    Circle().stroke(.white.opacity(0.055), style: StrokeStyle(lineWidth: 1, dash: [3, 6])).frame(width: 255, height: 255)
                    VStack(spacing: 9) {
                        Image(systemName: model.urls.count > 1 ? "doc.on.doc" : "doc").font(.system(size: 27, weight: .ultraLight)).foregroundStyle(orbitAccent)
                        Text(model.typeLabel).font(.system(size: 10, weight: .semibold, design: .monospaced)).tracking(1).lineLimit(1).frame(maxWidth: 100)
                    }.frame(width: 112, height: 112).background(.white.opacity(0.025), in: Circle()).overlay(Circle().stroke(.white.opacity(0.08)))
                    ForEach(Array(model.formats.enumerated()), id: \.element.id) { index, format in
                        let angle = Double(index) / Double(model.formats.count) * 2 * .pi - .pi / 2
                        FormatButton(format: format, subtitle: format.subtitle) { model.start(format) }
                            .offset(x: CGFloat(cos(angle)) * 133, y: CGFloat(sin(angle)) * 133)
                    }
                }.frame(height: 330).padding(.top, 4)
                Text(model.title).font(.system(size: 13, weight: .medium)).lineLimit(1).truncationMode(.middle).padding(.horizontal, 45)
                Text(model.urls.count > 1 && model.urls.allSatisfy { ConversionEngine.kind($0) == .image } ? "PDF объединит изображения в один документ" : "Выберите формат · сохранение в Загрузки/Orbit")
                    .font(.system(size: 11)).foregroundStyle(orbitMuted).padding(.top, 7)
                Spacer()
            }
        }
    }
    var working: some View {
        VStack(spacing: 0) {
            Spacer()
            ZStack {
                Circle().stroke(.white.opacity(0.07), lineWidth: 5)
                Circle().trim(from: 0, to: max(0.04, model.progress)).stroke(orbitAccent, style: StrokeStyle(lineWidth: 5, lineCap: .round)).rotationEffect(.degrees(-90)).animation(.easeOut(duration: 0.25), value: model.progress)
                VStack(spacing: 7) {
                    Image(systemName: model.selected?.icon ?? "arrow.triangle.2.circlepath").font(.system(size: 30, weight: .ultraLight)).foregroundStyle(orbitAccent)
                    Text(model.selected?.title ?? "").font(.system(size: 14, weight: .semibold, design: .rounded))
                }
            }.frame(width: 150, height: 150)
            Text("Конвертируем").font(.system(size: 24, weight: .medium)).padding(.top, 26)
            Text(model.detail).font(.system(size: 12)).foregroundStyle(orbitMuted).lineLimit(2).multilineTextAlignment(.center).padding(.horizontal, 35).padding(.top, 10)
            if model.selected?.id == "pdf" && UserDefaults.standard.string(forKey: "pdfEngine") == "office" && model.urls.contains(where: { ConversionEngine.kind($0) == .document }) {
                Text("macOS может запросить доступ к Word или Pages").font(.system(size: 10)).foregroundStyle(orbitMuted).padding(.top, 12)
            }
            Spacer()
            Button(model.cancellation.cancelled ? "Отменяем…" : "Отменить") { model.cancellation.cancel(); model.objectWillChange.send() }.buttonStyle(.plain).foregroundStyle(orbitMuted).font(.system(size: 12)).padding(.bottom, 30)
        }
    }
    var completion: some View {
        VStack(spacing: 0) {
            Spacer().frame(height: 28)
            Image(systemName: model.results.isEmpty && model.actionMessage == nil ? "exclamationmark.circle" : "checkmark.circle")
                .font(.system(size: 62, weight: .ultraLight)).foregroundStyle(model.results.isEmpty && model.actionMessage == nil ? Color.orange : orbitAccent)
            Text(model.actionMessage ?? (model.results.isEmpty ? "Не получилось" : (model.failures.isEmpty ? "Готово" : "Частично готово"))).font(.system(size: 25, weight: .medium)).multilineTextAlignment(.center).padding(.horizontal, 20).padding(.top, 19)
            if !model.results.isEmpty {
                Text(model.results.count == 1 ? model.results[0].lastPathComponent : "Создано результатов: \(model.results.count)")
                    .font(.system(size: 12)).foregroundStyle(orbitMuted).lineLimit(2).multilineTextAlignment(.center).padding(.horizontal, 30).padding(.top, 10)
            }
            if !model.results.isEmpty {
                Text("Сохранено: " + model.resultLocation).font(.system(size: 10)).foregroundStyle(orbitMuted).lineLimit(2).textSelection(.enabled).padding(.horizontal, 24).padding(.top, 8)
                if model.copiedResults { Text("Файл в буфере обмена · ⌘V, чтобы вставить").font(.system(size: 10)).foregroundStyle(orbitAccent).padding(.top, 8) }
            }
            if !model.failures.isEmpty {
                ScrollView { Text(model.failures.joined(separator: "\n\n")).font(.system(size: 12)).foregroundStyle(.white.opacity(0.68)).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading).padding(12) }
                    .frame(maxHeight: 110).background(.white.opacity(0.04), in: RoundedRectangle(cornerRadius: 12)).padding(.horizontal, 24).padding(.top, 16)
            }
            Spacer()
            if !model.results.isEmpty {
                Button { model.reveal(); model.close?() } label: {
                    Label("Показать в Finder", systemImage: "folder").font(.system(size: 13, weight: .semibold)).foregroundStyle(.black).frame(width: 230, height: 42).background(orbitAccent, in: RoundedRectangle(cornerRadius: 14))
                }.buttonStyle(.plain)
                Button { model.copyResults() } label: {
                    Label(model.copiedResults ? "Скопировать ещё раз" : "Скопировать файл", systemImage: "doc.on.doc").font(.system(size: 12)).foregroundStyle(orbitAccent)
                }.buttonStyle(.plain).padding(.top, 12)
            }
            Button("Другой формат") { model.retry() }.buttonStyle(.plain).font(.system(size: 12)).foregroundStyle(orbitMuted).padding(.top, 15).padding(.bottom, 25)
        }
    }
}

struct HomeView: View {
    @ObservedObject var model: OrbitModel
    let choose: () -> Void
    let install: () -> Void
    @State private var targeted = false
    @State private var settings = false
    @AppStorage("quality") var quality = 0.9
    @AppStorage("dpi") var dpi = 144.0
    @AppStorage("dragEnabled") var dragEnabled = true
    @AppStorage("pdfEngine") var pdfEngine = "native"
    @AppStorage("copyResults") var copyResults = true
    @AppStorage("showResultsInFinder") var showResultsInFinder = true
    let open: ([URL]) -> Void
    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                OrbitMark(size: 30)
                Text("orbit").font(.system(size: 23, weight: .semibold, design: .rounded)).tracking(0.5)
                Spacer()
                Text("FILE CONVERTER").font(.system(size: 9, weight: .medium, design: .monospaced)).tracking(2).foregroundStyle(orbitMuted)
                Button { settings.toggle() } label: { Image(systemName: "slider.horizontal.3").font(.system(size: 17)).foregroundStyle(.white.opacity(0.7)).frame(width: 35, height: 35) }.buttonStyle(.plain).help("Настройки")
                    .popover(isPresented: $settings, arrowEdge: .top) { settingsPanel.padding(20).frame(width: 320).background(DarkSurface()).preferredColorScheme(.dark) }
            }.padding(.top, 14)
            Text("Другой формат.\nОдно движение.").font(.system(size: 40, weight: .medium)).tracking(-1.5).lineSpacing(0).padding(.top, 28)
            Text("Перетащите файл, нажмите Shift и выберите формат.").font(.system(size: 14)).foregroundStyle(orbitMuted).padding(.top, 12)
            Button(action: choose) {
                VStack(spacing: 13) {
                    Image(systemName: "arrow.down.doc").font(.system(size: 31, weight: .ultraLight)).foregroundStyle(orbitAccent)
                    Text("Перетащите файлы сюда").font(.system(size: 16, weight: .medium)).foregroundStyle(.white)
                    Text("или нажмите, чтобы выбрать").font(.system(size: 12)).foregroundStyle(orbitMuted)
                    HStack(spacing: 7) { ForEach(["PDF", "DOCX", "HEIC", "PNG", "JPG"], id: \.self) { type in Text(type).font(.system(size: 9, weight: .medium, design: .monospaced)).foregroundStyle(.white.opacity(0.5)).padding(.horizontal, 9).padding(.vertical, 5).background(.white.opacity(0.04), in: Capsule()) } }.padding(.top, 4)
                }.frame(maxWidth: .infinity).frame(height: 198)
                    .background(orbitAccent.opacity(targeted ? 0.10 : 0.025), in: RoundedRectangle(cornerRadius: 24))
                    .overlay(RoundedRectangle(cornerRadius: 24).strokeBorder(orbitAccent.opacity(targeted ? 0.8 : 0.25), style: StrokeStyle(lineWidth: 1, dash: [5, 5])))
            }.buttonStyle(.plain).padding(.top, 27)
                .onDrop(of: [UTType.fileURL.identifier], isTargeted: $targeted) { providers in
                    let group = DispatchGroup(); let lock = NSLock(); var urls: [URL] = []
                    for p in providers { group.enter(); p.loadItem(forTypeIdentifier: UTType.fileURL.identifier, options: nil) { item, _ in
                        defer { group.leave() }
                        let url = (item as? URL) ?? (item as? Data).flatMap { URL(dataRepresentation: $0, relativeTo: nil) }
                        if let url = url { lock.lock(); urls.append(url); lock.unlock() }
                    } }
                    group.notify(queue: .main) { if !urls.isEmpty { open(urls.sorted { $0.path < $1.path }) } }; return true
                }
            HStack(spacing: 13) {
                Image(systemName: model.installed ? "checkmark.circle.fill" : "cursorarrow.click.2").font(.system(size: 25, weight: .light)).foregroundStyle(orbitAccent)
                VStack(alignment: .leading, spacing: 5) {
                    Text(model.installed ? "Пункт Finder включён" : "Добавьте в меню правого клика").font(.system(size: 13, weight: .medium))
                    Text("ПКМ по файлу → Конвертировать").font(.system(size: 10)).foregroundStyle(orbitMuted)
                }
                Spacer()
                Button(model.installed ? "Настроить" : "Включить") { install() }.buttonStyle(.plain).font(.system(size: 12, weight: .semibold)).foregroundStyle(orbitAccent).padding(.horizontal, 14).padding(.vertical, 9).background(orbitAccent.opacity(0.09), in: Capsule())
            }.padding(17).background(.white.opacity(0.035), in: RoundedRectangle(cornerRadius: 18)).padding(.top, 18)
            if let recent = model.history.first {
                HStack { Text("ПОСЛЕДНЕЕ").font(.system(size: 9, weight: .medium, design: .monospaced)).tracking(1).foregroundStyle(orbitMuted); Text(recent.name).font(.system(size: 11)).lineLimit(1); Spacer(); Button(recent.format + " ↗") { NSWorkspace.shared.activateFileViewerSelecting(recent.paths.map { URL(fileURLWithPath: $0) }) }.buttonStyle(.plain).font(.system(size: 11)).foregroundStyle(orbitAccent) }.padding(.top, 18)
            }
            Spacer(minLength: 18)
            HStack(spacing: 6) {
                Image(systemName: "lock.shield").font(.system(size: 10))
                Text("Файлы обрабатываются на вашем Mac").font(.system(size: 10))
                Spacer(); Text("v1.5").font(.system(size: 10, design: .monospaced))
            }.foregroundStyle(orbitMuted).padding(.bottom, 22)
        }.padding(.horizontal, 32).frame(width: 580, height: 650).background(DarkSurface()).preferredColorScheme(.dark)
    }
    var settingsPanel: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Настройки экспорта").font(.system(size: 17, weight: .medium))
            VStack(alignment: .leading, spacing: 5) {
                Text("Папка результатов").font(.system(size: 12, weight: .medium))
                HStack {
                    Text((model.outputDirectory.path as NSString).abbreviatingWithTildeInPath).font(.system(size: 10)).foregroundStyle(orbitMuted).lineLimit(2)
                    Spacer()
                    Button("Открыть") {
                        do {
                            try FileManager.default.createDirectory(at: model.outputDirectory, withIntermediateDirectories: true)
                            NSWorkspace.shared.open(model.outputDirectory)
                        } catch { NSAlert(error: error).runModal() }
                    }.buttonStyle(.plain).foregroundStyle(orbitAccent).font(.system(size: 11))
                }
            }
            Toggle("Круговое меню при перетаскивании", isOn: $dragEnabled).font(.system(size: 12)).tint(orbitAccent)
            Text("⇧ Форматы · ⌘ Инструменты · ⌃ Действия").font(.system(size: 10)).foregroundStyle(orbitMuted)
            Toggle("Копировать готовые файлы в буфер", isOn: $copyResults).font(.system(size: 12)).tint(orbitAccent)
            Toggle("Выделять результат в Finder", isOn: $showResultsInFinder).font(.system(size: 12)).tint(orbitAccent)
            Toggle("Запускать при входе", isOn: Binding(get: { SMAppService.mainApp.status == .enabled }, set: { enabled in
                do { if enabled { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }; model.objectWillChange.send() }
                catch { NSAlert(error: error).runModal() }
            })).font(.system(size: 12)).tint(orbitAccent)
            Picker("PDF документов", selection: $pdfEngine) {
                Text("Встроенный").tag("native")
                if ConversionEngine.wordAvailable || ConversionEngine.pagesAvailable { Text("Word / Pages").tag("office") }
            }.font(.system(size: 12))
            Text("Встроенный экспорт может изменить сложную вёрстку. Word / Pages требуют доступа к рабочей папке при первом экспорте.").font(.system(size: 10)).foregroundStyle(orbitMuted)
            HStack { Text("Качество JPG / HEIC").font(.system(size: 12)); Spacer(); Text("\(Int(quality*100))%").font(.system(size: 11, design: .monospaced)).foregroundStyle(orbitAccent) }
            Slider(value: $quality, in: 0.5...1.0, step: 0.05).tint(orbitAccent)
            Text("PDF → изображение").font(.system(size: 12))
            Picker("Разрешение", selection: $dpi) { Text("72 dpi").tag(72.0); Text("144 dpi").tag(144.0); Text("216 dpi").tag(216.0) }.pickerStyle(.segmented)
            Divider().padding(.vertical, 2)
            Button("Очистить историю") { model.history = []; model.saveHistory() }.buttonStyle(.plain).font(.system(size: 12)).foregroundStyle(orbitMuted)
        }
    }
}

class OrbitPanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { true }
}

struct ConversionFeedback: Equatable {
    let title: String
    let filename: String
    let copied: Bool
    let files: [URL]
}

struct ConversionToast: View {
    let feedback: ConversionFeedback
    let reveal: () -> Void
    let dismiss: () -> Void
    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: "checkmark.circle.fill").font(.system(size: 26)).foregroundStyle(orbitAccent)
            VStack(alignment: .leading, spacing: 5) {
                Text(feedback.title).font(.system(size: 14, weight: .semibold))
                Text(feedback.filename).font(.system(size: 11)).lineLimit(1).truncationMode(.middle)
                HStack {
                    Text(feedback.copied ? "Скопировано · ⌘V для вставки" : "Сохранено в Загрузки/Orbit").font(.system(size: 10)).foregroundStyle(orbitMuted)
                    Spacer(minLength: 3)
                    Button("Показать") { reveal() }.buttonStyle(.plain).font(.system(size: 10, weight: .semibold)).foregroundStyle(orbitAccent)
                }
            }
            Button { dismiss() } label: { Image(systemName: "xmark").font(.system(size: 9)).foregroundStyle(orbitMuted) }.buttonStyle(.plain)
        }.padding(17).frame(width: 360).background(DarkSurface()).clipShape(RoundedRectangle(cornerRadius: 18)).overlay(RoundedRectangle(cornerRadius: 18).stroke(.white.opacity(0.16))).preferredColorScheme(.dark)
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate, NSWindowDelegate {
    let model = OrbitModel()
    var statusItem: NSStatusItem!
    var home: NSWindow?
    var panel: OrbitPanel?
    var feedbackPanel: NSPanel?
    var dismissFeedback: DispatchWorkItem?
    var pending: [URL] = []
    var incoming: DispatchWorkItem?
    var keyMonitor: Any?
    var launching = true
    let dragObserver = DragObserver()
    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
        NSApp.servicesProvider = self; NSUpdateDynamicServices()
        model.close = { [weak self] in self?.panel?.orderOut(nil) }
        model.choose = { [weak self] in self?.chooseFiles() }
        model.didComplete = { [weak self] feedback in self?.showFeedback(feedback) }
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        statusItem.button?.image = NSImage(systemSymbolName: "arrow.triangle.2.circlepath.circle", accessibilityDescription: "Orbit")
        let menu = NSMenu()
        menu.addItem(withTitle: "Orbit — конвертер файлов", action: nil, keyEquivalent: "")
        menu.addItem(.separator())
        menu.addItem(withTitle: "Выбрать файлы…", action: #selector(chooseFiles), keyEquivalent: "o").target = self
        menu.addItem(withTitle: "Открыть Orbit", action: #selector(showHome), keyEquivalent: "").target = self
        menu.addItem(withTitle: "Добавить действие macOS", action: #selector(installAction), keyEquivalent: "").target = self
        menu.addItem(.separator())
        menu.addItem(withTitle: "Завершить Orbit", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        statusItem.menu = menu
        dragObserver.onShow = { [weak self] files, mode in self?.present(files, dragSession: true, mode: mode) }
        dragObserver.onMode = { [weak self] mode in if self?.model.phase == .choose && self?.model.dragSession == true { self?.model.mode = mode } }
        dragObserver.onEnd = { [weak self] in
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.20) {
                if self?.model.phase == .choose && self?.model.dragSession == true { self?.panel?.orderOut(nil); self?.model.dragSession = false }
            }
        }
        dragObserver.start()
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown, .flagsChanged]) { [weak self] event in
            if event.type == .flagsChanged && self?.panel?.isVisible == true && self?.model.phase == .choose {
                if event.modifierFlags.contains(.control) { self?.model.mode = .actions }
                else if event.modifierFlags.contains(.command) { self?.model.mode = .tools }
                else if event.modifierFlags.contains(.shift) { self?.model.mode = .convert }
                return event
            }
            if event.modifierFlags.contains(.command) {
                if event.keyCode == 12 { NSApp.terminate(nil); return nil }
                if event.keyCode == 31 { self?.chooseFiles(); return nil }
            }
            if event.keyCode == 53, self?.panel?.isVisible == true {
                if self?.model.busy == true { self?.model.cancellation.cancel() }
                else { self?.panel?.orderOut(nil) }
                return nil
            }
            return event
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.45) { [weak self] in
            guard let self = self else { return }; self.launching = false
            if self.pending.isEmpty && self.panel?.isVisible != true { self.showHome() }
        }
    }
    func applicationDidBecomeActive(_ notification: Notification) { model.refreshInstalled() }
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool { if !flag { showHome() }; return true }
    func application(_ application: NSApplication, open urls: [URL]) { enqueue(SelectionLink.files(from: urls)) }
    func application(_ sender: NSApplication, openFiles filenames: [String]) { enqueue(filenames.map { URL(fileURLWithPath: $0) }); sender.reply(toOpenOrPrint: .success) }
    @objc func convertFiles(_ pasteboard: NSPasteboard, userData: String?, error: AutoreleasingUnsafeMutablePointer<NSString?>) {
        var urls = pasteboard.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL] ?? []
        if urls.isEmpty, let paths = pasteboard.propertyList(forType: NSPasteboard.PasteboardType("NSFilenamesPboardType")) as? [String] { urls = paths.map { URL(fileURLWithPath: $0) } }
        if urls.isEmpty { error.pointee = "Приложение не передало файл. Используйте действие в Finder или перетащите файл в Orbit."; return }
        enqueue(urls)
    }
    func enqueue(_ urls: [URL]) {
        pending.append(contentsOf: urls.filter { $0.isFileURL }); incoming?.cancel()
        let item = DispatchWorkItem { [weak self] in
            guard let self = self else { return }
            let files = Array(NSOrderedSet(array: self.pending)) as? [URL] ?? self.pending
            self.pending = []; self.present(files)
        }
        incoming = item; DispatchQueue.main.asyncAfter(deadline: .now() + 0.18, execute: item)
    }
    func present(_ urls: [URL], dragSession: Bool = false, mode: WheelMode = .convert) {
        guard !urls.isEmpty else { return }
        if model.busy { NSApp.activate(ignoringOtherApps: true); panel?.makeKeyAndOrderFront(nil); NSSound.beep(); return }
        model.prepare(urls); model.dragSession = dragSession; model.mode = mode; home?.orderOut(nil)
        if panel == nil {
            let p = OrbitPanel(contentRect: NSRect(x: 0, y: 0, width: 430, height: 460), styleMask: [.borderless], backing: .buffered, defer: false)
            p.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient]
            p.isOpaque = false; p.backgroundColor = .clear; p.hasShadow = false; p.level = .popUpMenu
            p.acceptsMouseMovedEvents = true; p.isMovableByWindowBackground = false; p.hidesOnDeactivate = false; p.isReleasedWhenClosed = false
            p.contentView = NSHostingView(rootView: OrbitShell(model: model)); panel = p
        }
        let mouse = NSEvent.mouseLocation
        let screen = NSScreen.screens.first { $0.frame.contains(mouse) } ?? NSScreen.main!
        let bounds = screen.visibleFrame
        let x = min(max(mouse.x - 215, bounds.minX + 12), bounds.maxX - 442)
        let y = min(max(mouse.y - 230, bounds.minY + 12), bounds.maxY - 472)
        panel?.setFrameOrigin(NSPoint(x: x, y: y))
        if dragSession { panel?.orderFrontRegardless() }
        else { panel?.makeKeyAndOrderFront(nil); NSApp.activate(ignoringOtherApps: true) }
    }
    func showFeedback(_ feedback: ConversionFeedback) {
        dismissFeedback?.cancel()
        let screen = NSScreen.screens.first { $0.frame.contains(NSEvent.mouseLocation) } ?? NSScreen.main!
        let bounds = screen.visibleFrame
        let notice = feedbackPanel ?? NSPanel(contentRect: NSRect(x: 0, y: 0, width: 360, height: 104), styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        notice.title = "Orbit — Готово"
        notice.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient]
        notice.isOpaque = false; notice.backgroundColor = .clear; notice.hasShadow = true
        notice.level = .statusBar; notice.hidesOnDeactivate = false; notice.isReleasedWhenClosed = false
        notice.contentView = NSHostingView(rootView: ConversionToast(feedback: feedback, reveal: { NSWorkspace.shared.activateFileViewerSelecting(feedback.files) }, dismiss: { [weak notice] in notice?.orderOut(nil) }))
        notice.setFrame(NSRect(x: bounds.maxX - 376, y: bounds.maxY - 120, width: 360, height: 104), display: true)
        notice.orderFrontRegardless(); feedbackPanel = notice
        if let path = ProcessInfo.processInfo.environment["ORBIT_INPUT_TRACE"], let view = notice.contentView,
           let bitmap = view.bitmapImageRepForCachingDisplay(in: view.bounds) {
            view.cacheDisplay(in: view.bounds, to: bitmap)
            try? bitmap.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: path + ".toast.png"))
        }
        let dismiss = DispatchWorkItem { [weak notice] in notice?.orderOut(nil) }
        dismissFeedback = dismiss; DispatchQueue.main.asyncAfter(deadline: .now() + 7, execute: dismiss)
    }
    @objc func chooseFiles() {
        let dialog = NSOpenPanel(); dialog.canChooseDirectories = false; dialog.allowsMultipleSelection = true
        dialog.title = "Выберите файлы для конвертации"; dialog.prompt = "Конвертировать"
        NSApp.activate(ignoringOtherApps: true)
        if dialog.runModal() == .OK { present(dialog.urls) }
    }
    @objc func showHome() {
        model.refreshInstalled()
        if home == nil {
            let w = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 580, height: 650), styleMask: [.titled, .closable, .miniaturizable, .fullSizeContentView], backing: .buffered, defer: false)
            w.title = "Orbit"; w.titlebarAppearsTransparent = true; w.titleVisibility = .hidden; w.backgroundColor = NSColor(calibratedWhite: 0.06, alpha: 1)
            w.collectionBehavior = [.moveToActiveSpace, .fullScreenAuxiliary]
            w.isReleasedWhenClosed = false; w.center()
            w.contentView = NSHostingView(rootView: HomeView(model: model, choose: { [weak self] in self?.chooseFiles() }, install: { [weak self] in self?.installAction() }, open: { [weak self] files in self?.present(files) }))
            home = w
        }
        NSApp.activate(ignoringOtherApps: true); home?.makeKeyAndOrderFront(nil)
    }
    @objc func installAction() {
        do {
            try WorkflowInstaller.install(app: Bundle.main.bundleURL)
            FIFinderSyncController.showExtensionManagementInterface()
            model.refreshInstalled()

        } catch { let alert = NSAlert(error: error); alert.runModal() }
    }
}

enum WorkflowInstaller {
    static func install(app: URL, destination: URL? = nil) throws {
        let source = app.appendingPathComponent("Contents/Resources/Конвертировать с Orbit.workflow")
        let parent = destination ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Services")
        try FileManager.default.createDirectory(at: parent, withIntermediateDirectories: true)
        let target = parent.appendingPathComponent(source.lastPathComponent)
        let temp = parent.appendingPathComponent(".orbit-\(UUID().uuidString).workflow")
        try FileManager.default.copyItem(at: source, to: temp)
        defer { try? FileManager.default.removeItem(at: temp) }
        let file = temp.appendingPathComponent("Contents/document.wflow")
        var data = try PropertyListSerialization.propertyList(from: Data(contentsOf: file), format: nil) as! [String: Any]
        var actions = data["actions"] as! [[String: Any]]
        var action = actions[0]["action"] as! [String: Any]
        var params = action["ActionParameters"] as! [String: Any]
        let quoted = "'" + app.path.replacingOccurrences(of: "'", with: "'\\''") + "'"
        params["COMMAND_STRING"] = "/usr/bin/open -a " + quoted + " -- \"$@\""
        action["ActionParameters"] = params; actions[0]["action"] = action; data["actions"] = actions
        try PropertyListSerialization.data(fromPropertyList: data, format: .xml, options: 0).write(to: file)
        if FileManager.default.fileExists(atPath: target.path) {
            let existing = target.appendingPathComponent("Contents/Info.plist")
            guard let info = NSDictionary(contentsOf: existing), info["OrbitWorkflow"] as? Bool == true else { throw OrbitError("Действие с таким именем уже существует и создано не Orbit. Переименуйте его перед установкой.") }
            _ = try FileManager.default.replaceItemAt(target, withItemAt: temp)
        } else { try FileManager.default.moveItem(at: temp, to: target) }
        // Register the newly installed workflow immediately, rather than waiting for
        // the next Services scan after login. Do not flush other applications' entries.
        for args in [["-read_bundle", target.path], ["-update"]] {
            let process = Process(); process.executableURL = URL(fileURLWithPath: "/System/Library/CoreServices/pbs")
            process.arguments = args; process.standardOutput = FileHandle.nullDevice; process.standardError = FileHandle.nullDevice
            do { try process.run(); process.waitUntilExit() } catch { /* Registration will be retried by macOS. */ }
        }
        NSUpdateDynamicServices()
        if destination == nil {
            let ext = app.appendingPathComponent("Contents/PlugIns/OrbitFinder.appex")
            if FileManager.default.fileExists(atPath: ext.path) {
                let register = Process(); register.executableURL = URL(fileURLWithPath: "/usr/bin/pluginkit")
                register.arguments = ["-a", ext.path]
                try register.run(); register.waitUntilExit()
                guard register.terminationStatus == 0 else { throw OrbitError("Не удалось зарегистрировать расширение Finder. Переместите Orbit в «Программы» и откройте снова.") }
            }
        }
    }
}
