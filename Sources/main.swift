import AppKit

let arguments = Array(CommandLine.arguments.dropFirst())
if arguments.first == "--convert", arguments.count >= 3 {
    let format = arguments[1]
    let input = URL(fileURLWithPath: arguments[2])
    let output = arguments.count >= 4 ? URL(fileURLWithPath: arguments[3], isDirectory: true) : nil
    do { let results = try ConversionEngine(outputDirectory: output).convertFiles(input, to: format); results.forEach { print($0.path) } }
    catch { fputs(error.localizedDescription + "\n", stderr); exit(1) }
} else if arguments.first == "--install-action" {
    do {
        let destination = arguments.count > 1 ? URL(fileURLWithPath: arguments[1], isDirectory: true) : nil
        try WorkflowInstaller.install(app: Bundle.main.bundleURL, destination: destination); print("Действие установлено.")
    } catch { fputs(error.localizedDescription + "\n", stderr); exit(1) }
} else {
    let app = NSApplication.shared
    let delegate = AppDelegate()
    app.delegate = delegate
    if !arguments.isEmpty { delegate.pending = arguments.map { URL(fileURLWithPath: $0) } }
    if !delegate.pending.isEmpty {
        let urls = delegate.pending; delegate.pending = []
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) { delegate.present(urls) }
    }
    app.run()
}
