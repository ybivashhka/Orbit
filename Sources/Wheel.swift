import AppKit
import SwiftUI
import UniformTypeIdentifiers

enum OrbitInputTrace {
    static func record(_ message: String) {
        guard let path = ProcessInfo.processInfo.environment["ORBIT_INPUT_TRACE"] else { return }
        let line = Data((message + "\n").utf8)
        if let file = FileHandle(forWritingAtPath: path) {
            defer { try? file.close() }; _ = try? file.seekToEnd(); try? file.write(contentsOf: line)
        } else { try? line.write(to: URL(fileURLWithPath: path)) }
    }
}

enum WheelMode: String, CaseIterable {
    case convert, tools, actions
    var label: String { switch self { case .convert: return "Форматы"; case .tools: return "Инструменты"; case .actions: return "Действия" } }
    var key: String { switch self { case .convert: return "⇧"; case .tools: return "⌘"; case .actions: return "⌃" } }
}

struct RingSector: Shape {
    let index: Int
    let count: Int
    func path(in rect: CGRect) -> Path {
        let center = CGPoint(x: rect.midX, y: rect.midY)
        let outer = min(rect.width, rect.height) / 2 - 3
        let inner = outer * 0.43
        let step = 360.0 / Double(max(1, count))
        let gap = min(2.1, step * 0.07)
        let start = -90 + Double(index) * step - step / 2 + gap
        let end = start + step - gap * 2
        var p = Path()
        p.addArc(center: center, radius: outer, startAngle: .degrees(start), endAngle: .degrees(end), clockwise: false)
        p.addArc(center: center, radius: inner, startAngle: .degrees(end), endAngle: .degrees(start), clockwise: true)
        p.closeSubpath()
        return p
    }
}

struct WheelSegment: View {
    let option: Format
    let index: Int
    let count: Int
    let highlighted: Bool
    var active: Bool { highlighted }
    var shape: RingSector { RingSector(index: index, count: count) }
    var body: some View {
        let angle = Double(index) / Double(count) * 2 * .pi - .pi / 2
        ZStack {
                shape.fill(.ultraThinMaterial)
                shape.fill(active ? orbitAccent.opacity(0.92) : Color.white.opacity(0.055))
                shape.stroke(active ? orbitAccent : Color.white.opacity(0.20), lineWidth: 0.8)
                VStack(spacing: 6) {
                    Image(systemName: option.icon).font(.system(size: count > 7 ? 16 : 20, weight: .regular))
                    Text(option.title).font(.system(size: count > 7 ? 10 : 11, weight: .semibold, design: .rounded)).lineLimit(1).minimumScaleFactor(0.6).frame(width: count > 7 ? 58 : 76)
                }.foregroundStyle(active ? Color.black : Color.white.opacity(0.95))
                    .offset(x: cos(angle) * 117, y: sin(angle) * 117)
        }.frame(width: 332, height: 332)
            .allowsHitTesting(false)
            .accessibilityHidden(true)
            .animation(.easeOut(duration: 0.12), value: active)
    }
}

struct OrbitShell: View {
    @ObservedObject var model: OrbitModel
    var body: some View {
        Group {
            if model.phase == .choose { wheel }
            else { RadialView(model: model) }
        }.preferredColorScheme(.dark)
    }
    var wheel: some View {
        VStack(spacing: 0) {
            HStack(spacing: 5) {
                ForEach(WheelMode.allCases, id: \.self) { mode in
                    Button { model.mode = mode } label: {
                        Text(mode.key + " " + mode.label).font(.system(size: 10, weight: .medium))
                            .foregroundStyle(model.mode == mode ? Color.black : .white.opacity(0.72))
                            .padding(.horizontal, 11).padding(.vertical, 7)
                            .background(model.mode == mode ? AnyShapeStyle(orbitAccent) : AnyShapeStyle(.ultraThinMaterial), in: Capsule())
                    }.buttonStyle(.plain)
                }
                Button { model.close?() } label: { Image(systemName: "xmark").font(.system(size: 10, weight: .medium)).foregroundStyle(.white.opacity(0.75)).frame(width: 27, height: 27).background(.ultraThinMaterial, in: Circle()) }.buttonStyle(.plain)
            }.padding(.top, 18).padding(.bottom, 12)
            ZStack {
                if model.wheelOptions.isEmpty {
                    Circle().stroke(.white.opacity(0.12), lineWidth: 1).frame(width: 325, height: 325)
                    Text("Для этого файла нет доступных форматов.\nОткройте «Инструменты» или «Действия».").font(.system(size: 11)).foregroundStyle(.white.opacity(0.8)).multilineTextAlignment(.center).frame(width: 260).offset(y: 114)
                }
                Circle().fill(.ultraThinMaterial).frame(width: 132, height: 132)
                Circle().fill(Color.black.opacity(0.18)).frame(width: 132, height: 132)
                VStack(spacing: 7) {
                    if let first = model.urls.first {
                        Image(nsImage: NSWorkspace.shared.icon(forFile: first.path)).resizable().scaledToFit().frame(width: 43, height: 43)
                    }
                    Text(model.urls.count > 1 ? "\(model.urls.count) файлов" : model.typeLabel).font(.system(size: 9, weight: .semibold, design: .monospaced)).foregroundStyle(.white.opacity(0.85)).lineLimit(1).frame(maxWidth: 98)
                }
                ForEach(Array(model.wheelOptions.enumerated()), id: \.element.id) { i, option in
                    WheelSegment(option: option, index: i, count: model.wheelOptions.count, highlighted: model.dragHover == i)
                }
                WheelInputSurface(model: model).frame(width: 332, height: 332)
            }.frame(width: 332, height: 332)
                .shadow(color: .black.opacity(0.30), radius: 18, y: 7)
            Text(model.title).font(.system(size: 11, weight: .medium)).foregroundStyle(.white).lineLimit(1).truncationMode(.middle)
                .padding(.horizontal, 13).padding(.vertical, 7).background(.ultraThinMaterial, in: Capsule()).padding(.top, 10).frame(maxWidth: 320)
            Text(model.dragSession ? "Бросьте файл на нужный сектор" : "Выберите сектор · Esc — закрыть")
                .font(.system(size: 10)).foregroundStyle(.white.opacity(0.75)).padding(.horizontal, 12).padding(.vertical, 5).background(.ultraThinMaterial, in: Capsule()).padding(.top, 5)
            Spacer(minLength: 0)
        }.frame(width: 430, height: 460)
    }
}

/// The drawing, hover, click and drop share this geometry, in top-left coordinates.
enum WheelGeometry {
    static func selection(at point: CGPoint, count: Int, size: CGSize = CGSize(width: 332, height: 332)) -> Int? {
        guard count > 0 else { return nil }
        let x = point.x - size.width / 2, y = point.y - size.height / 2
        let outer = min(size.width, size.height) / 2 - 3
        let radius = hypot(x, y)
        guard radius >= outer * 0.43, radius <= outer else { return nil }
        let step = 2 * Double.pi / Double(count)
        let gap = min(2.1 * Double.pi / 180, step * 0.07)
        var angle = atan2(Double(y), Double(x)) + Double.pi / 2
        if angle < 0 { angle += 2 * Double.pi }
        let index = Int(floor((angle + step / 2) / step)) % count
        let distance = abs(atan2(sin(angle - Double(index) * step), cos(angle - Double(index) * step)))
        return distance <= step / 2 - gap ? index : nil
    }
}

struct WheelInputSurface: NSViewRepresentable {
    @ObservedObject var model: OrbitModel
    func makeNSView(context: Context) -> WheelInputView { WheelInputView() }
    func updateNSView(_ view: WheelInputView, context: Context) {
        view.options = model.wheelOptions
        view.onDragHover = { if model.dragHover != $0 { model.dragHover = $0 } }
        view.onSelect = { model.perform($0) }
    }
}

/// Each sector is an AppKit button. Hover stays inside AppKit: it must not
/// rebuild the SwiftUI hosting tree while the button is tracking a press.
final class WheelSectorButton: NSButton {
    let option: Format
    let index: Int
    let count: Int
    var select: ((Format) -> Void)?
    private var hover = false
    private var secondaryPressed = false
    private var area: NSTrackingArea?
    override var isFlipped: Bool { true }
    override var mouseDownCanMoveWindow: Bool { false }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    init(option: Format, index: Int, count: Int) {
        self.option = option; self.index = index; self.count = count
        super.init(frame: NSRect(x: 0, y: 0, width: 332, height: 332))
        title = option.title; isBordered = false; setButtonType(.momentaryChange)
        target = self; action = #selector(chosen)
        setAccessibilityLabel(option.title); setAccessibilityHelp(option.subtitle)
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    func contains(_ point: NSPoint) -> Bool { WheelGeometry.selection(at: point, count: count, size: bounds.size) == index }
    override func hitTest(_ point: NSPoint) -> NSView? {
        let local = convert(point, from: superview)
        return !isHidden && contains(local) ? self : nil
    }
    override func accessibilityFrame() -> NSRect {
        guard let window = window else { return .zero }
        let angle = Double(index) * 2 * .pi / Double(count) - .pi / 2
        let rect = NSRect(x: bounds.midX + cos(angle) * 117 - 25, y: bounds.midY + sin(angle) * 117 - 25, width: 50, height: 50)
        return window.convertToScreen(convert(rect, to: nil))
    }
    @objc private func chosen() {
        if let event = NSApp.currentEvent, event.window === window,
           event.type == .leftMouseUp || event.type == .rightMouseUp,
           !contains(convert(event.locationInWindow, from: nil)) { return }
        OrbitInputTrace.record("native button " + option.id)
        let callback = select
        hover = false; needsDisplay = true
        callback?(option)
    }
    override func rightMouseDown(with event: NSEvent) { secondaryPressed = contains(convert(event.locationInWindow, from: nil)) }
    override func rightMouseUp(with event: NSEvent) {
        let pressed = secondaryPressed; secondaryPressed = false
        if pressed && contains(convert(event.locationInWindow, from: nil)) { performClick(nil) }
    }
    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let area = area { removeTrackingArea(area) }
        let tracking = NSTrackingArea(rect: .zero, options: [.activeAlways, .inVisibleRect, .mouseMoved, .mouseEnteredAndExited], owner: self)
        addTrackingArea(tracking); area = tracking
    }
    private func updateHover(_ event: NSEvent) {
        let next = contains(convert(event.locationInWindow, from: nil))
        if hover != next { hover = next; needsDisplay = true }
    }
    override func mouseMoved(with event: NSEvent) { updateHover(event) }
    override func mouseEntered(with event: NSEvent) { updateHover(event) }
    override func mouseExited(with event: NSEvent) { hover = false; needsDisplay = true }
    override func draw(_ dirtyRect: NSRect) {
        guard hover || isHighlighted else { return }
        let path = RingSector(index: index, count: count).path(in: bounds).cgPath
        guard let context = NSGraphicsContext.current?.cgContext else { return }
        context.saveGState(); context.addPath(path)
        context.setFillColor(NSColor(calibratedRed: 0.72, green: 0.96, blue: 0.43, alpha: 0.96).cgColor); context.fillPath(); context.restoreGState()
        let angle = Double(index) * 2 * .pi / Double(count) - .pi / 2
        let center = NSPoint(x: bounds.midX + cos(angle) * 117, y: bounds.midY + sin(angle) * 117)
        let iconSize: CGFloat = count > 7 ? 16 : 20
        if let symbol = NSImage(systemSymbolName: option.icon, accessibilityDescription: nil)?.withSymbolConfiguration(.init(pointSize: iconSize, weight: .regular)) {
            let ratio = symbol.size.width / max(1, symbol.size.height)
            let iconRect = NSRect(x: center.x - iconSize * ratio / 2, y: center.y - 23, width: iconSize * ratio, height: iconSize)
            symbol.draw(in: iconRect, from: .zero, operation: .sourceOver, fraction: 1, respectFlipped: true, hints: nil)
        }
        let text = NSAttributedString(string: option.title, attributes: [.font: NSFont.systemFont(ofSize: count > 7 ? 10 : 11, weight: .semibold), .foregroundColor: NSColor.black])
        let size = text.size(); text.draw(at: NSPoint(x: center.x - size.width / 2, y: center.y + 4))
    }
}

final class WheelInputView: NSView {
    var options: [Format] = [] {
        didSet { if options.map(\.id) != oldValue.map(\.id) { rebuildButtons() } }
    }
    var onSelect: ((Format) -> Void)?
    var onDragHover: ((Int?) -> Void)?
    private(set) var sectorButtons: [WheelSectorButton] = []
    override var isFlipped: Bool { true }
    override var mouseDownCanMoveWindow: Bool { false }
    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        registerForDraggedTypes([.fileURL]); setAccessibilityElement(false)
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    private func rebuildButtons() {
        sectorButtons.forEach { $0.removeFromSuperview() }
        sectorButtons = options.enumerated().map { index, option in
            let button = WheelSectorButton(option: option, index: index, count: options.count)
            button.select = { [weak self] option in self?.activate(option) }
            addSubview(button); return button
        }
    }
    func selection(at point: CGPoint) -> Int? { WheelGeometry.selection(at: point, count: options.count, size: bounds.size) }
    func activate(_ option: Format) { onSelect?(option) }
    override func hitTest(_ point: NSPoint) -> NSView? {
        let local = convert(point, from: superview)
        guard let index = selection(at: local) else { return nil }
        return sectorButtons[index]
    }
    private func dragSelection(_ sender: NSDraggingInfo) -> Int? {
        guard sender.draggingPasteboard.canReadObject(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) else { return nil }
        let index = selection(at: convert(sender.draggingLocation, from: nil))
        onDragHover?(index); return index
    }
    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation { dragSelection(sender) == nil ? [] : .copy }
    override func draggingUpdated(_ sender: NSDraggingInfo) -> NSDragOperation { dragSelection(sender) == nil ? [] : .copy }
    override func draggingExited(_ sender: NSDraggingInfo?) { onDragHover?(nil) }
    override func prepareForDragOperation(_ sender: NSDraggingInfo) -> Bool { dragSelection(sender) != nil }
    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        guard let index = dragSelection(sender) else { return false }
        let option = options[index], select = onSelect
        onDragHover?(nil)
        DispatchQueue.main.async { select?(option) }
        return true
    }
}

/// Observes only the drag pasteboard and modifier/button state. No key logging,
/// event taps, Accessibility permission, clipboard history, or network access.
final class DragObserver {
    private var timer: Timer?
    private let pasteboard = NSPasteboard(name: .drag)
    private var idleChange = 0
    private var wasDown = false
    private var mouseStart = NSPoint.zero
    private var shownForDrag = false
    private var lastMode: WheelMode?
    var onShow: (([URL], WheelMode) -> Void)?
    var onMode: ((WheelMode) -> Void)?
    var onEnd: (() -> Void)?
    func start() {
        idleChange = pasteboard.changeCount
        timer = Timer(timeInterval: 0.045, repeats: true) { [weak self] _ in self?.tick() }
        RunLoop.main.add(timer!, forMode: .common)
    }
    func stop() { timer?.invalidate(); timer = nil }
    private func tick() {
        if UserDefaults.standard.object(forKey: "dragEnabled") as? Bool == false { return }
        let down = NSEvent.pressedMouseButtons & 1 != 0
        if !down {
            if wasDown && shownForDrag { onEnd?() }
            wasDown = false; shownForDrag = false; lastMode = nil; idleChange = pasteboard.changeCount
            return
        }
        if !wasDown { mouseStart = NSEvent.mouseLocation; wasDown = true }
        let flags = NSEvent.modifierFlags
        let mode: WheelMode? = flags.contains(.control) ? .actions : (flags.contains(.command) ? .tools : (flags.contains(.shift) ? .convert : nil))
        if shownForDrag {
            if let mode = mode, mode != lastMode { lastMode = mode; onMode?(mode) }
            return
        }
        guard let mode = mode, pasteboard.changeCount != idleChange else { return }
        let mouse = NSEvent.mouseLocation
        guard hypot(mouse.x - mouseStart.x, mouse.y - mouseStart.y) > 4 else { return }
        let files = pasteboard.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL] ?? []
        guard !files.isEmpty else { return }
        shownForDrag = true; lastMode = mode; onShow?(files, mode)
    }
}
