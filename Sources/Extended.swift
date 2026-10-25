import Foundation
import AVFoundation

enum ExtraConversions {
    static let wav = Format(id: "wav", title: "WAV", subtitle: "Аудио PCM, 16 бит", icon: "waveform")
    static let aiff = Format(id: "aiff", title: "AIFF", subtitle: "Аудио PCM для Mac", icon: "waveform")
    static let m4a = Format(id: "m4a", title: "M4A", subtitle: "Аудио AAC", icon: "music.note")
    static let mp4 = Format(id: "mp4", title: "MP4", subtitle: "Видео MP4", icon: "film")
    static let mov = Format(id: "mov", title: "MOV", subtitle: "Видео QuickTime", icon: "film.stack")
    static let zip = Format(id: "zip", title: "ZIP", subtitle: "ZIP-архив", icon: "archivebox")
    static let tar = Format(id: "tar", title: "TAR", subtitle: "Архив без сжатия", icon: "archivebox")
    static let tgz = Format(id: "tar.gz", title: "TGZ", subtitle: "TAR с gzip-сжатием", icon: "archivebox.fill")
    static let srt = Format(id: "srt", title: "SRT", subtitle: "Субтитры SubRip", icon: "captions.bubble")
    static let vtt = Format(id: "vtt", title: "VTT", subtitle: "Субтитры WebVTT", icon: "captions.bubble")
    static let csv = Format(id: "csv", title: "CSV", subtitle: "Таблица с разделителем-запятой", icon: "tablecells")
    static let tsv = Format(id: "tsv", title: "TSV", subtitle: "Таблица с табуляцией", icon: "tablecells")
    static func kind(_ url: URL) -> FileKind? {
        switch url.pathExtension.lowercased() {
        case "mp3", "m4a", "wav", "aif", "aiff", "caf", "flac": return .audio
        case "mov", "mp4", "m4v": return .video
        case "zip", "tar", "gz", "tgz", "bz2", "xz", "rar": return .archive
        case "srt", "vtt": return .subtitle
        case "csv", "tsv": return .table
        default: return nil
        }
    }
    static func formats(_ url: URL) -> [Format] {
        let ext = url.pathExtension.lowercased()
        switch kind(url) {
        case .audio: return [wav, aiff, m4a].filter { $0.id != ext && !(ext == "aif" && $0.id == "aiff") }
        case .video: return [mp4, mov, m4a].filter { $0.id != ext }
        case .archive: return [zip, tar, tgz].filter { $0.id != ext && !(ext == "gz" && $0.id == "tar.gz") && !(ext == "tgz" && $0.id == "tar.gz") }
        case .subtitle: return [srt, vtt, .txt].filter { $0.id != ext }
        case .table: return [csv, tsv].filter { $0.id != ext }
        default: return []
        }
    }
    static func convert(_ input: URL, to format: String, engine: ConversionEngine, progress: (Double) -> Void) throws -> URL {
        let output = try engine.unique(input, ext: format)
        switch kind(input) {
        case .subtitle:
            let text = try String(contentsOf: input, encoding: .utf8)
            try engine.write(Data(subtitles(text, format: format).utf8), to: output)
        case .table:
            let text = try String(contentsOf: input, encoding: .utf8)
            let rows = try parseTable(text, separator: input.pathExtension.lowercased() == "csv" ? "," : "\t")
            let delimiter = format == "csv" ? "," : "\t"
            let result = rows.map { row in row.map { value -> String in
                if value.contains(delimiter) || value.contains("\"") || value.contains("\n") || value.contains("\r") { return "\"" + value.replacingOccurrences(of: "\"", with: "\"\"") + "\"" }; return value
            }.joined(separator: delimiter) }.joined(separator: "\r\n") + "\r\n"
            try engine.write(Data(result.utf8), to: output)
        case .audio:
            try withTemporaryFolder(engine) { temp in
                let generated = temp.appendingPathComponent("converted." + format)
                let settings: [String]
                switch format { case "wav": settings = ["-f", "WAVE", "-d", "LEI16"]; case "aiff": settings = ["-f", "AIFF", "-d", "BEI16"]; default: settings = ["-f", "m4af", "-d", "aac", "-b", "192000"] }
                try engine.process("/usr/bin/afconvert", [input.path, generated.path] + settings, timeout: 300)
                try engine.check(); try engine.fm.copyItem(at: generated, to: output)
            }
        case .video:
            try withTemporaryFolder(engine) { temp in
                let asset = AVURLAsset(url: input)
                let preset = format == "m4a" ? AVAssetExportPresetAppleM4A : AVAssetExportPresetHighestQuality
                guard let session = AVAssetExportSession(asset: asset, presetName: preset) else { throw OrbitError("macOS не может прочитать этот видеофайл.") }
                let fileType: AVFileType = format == "mov" ? .mov : (format == "m4a" ? .m4a : .mp4)
                guard session.supportedFileTypes.contains(fileType) else { throw OrbitError("У этого файла нет дорожки или кодека для выбранного формата.") }
                let generated = temp.appendingPathComponent("converted." + format)
                session.outputURL = generated; session.outputFileType = fileType; session.shouldOptimizeForNetworkUse = false
                let finished = DispatchSemaphore(value: 0)
                session.exportAsynchronously { finished.signal() }
                let deadline = Date().addingTimeInterval(600)
                while finished.wait(timeout: .now() + 0.12) == .timedOut {
                    if engine.isCancelled() || Date() > deadline { session.cancelExport(); throw OrbitError(engine.isCancelled() ? "Конвертация отменена." : "Видео обрабатывается дольше 10 минут. Попробуйте более короткий файл.") }
                    progress(Double(session.progress))
                }
                guard session.status == .completed else { throw OrbitError(session.error?.localizedDescription ?? "Не удалось конвертировать видео.") }
                try engine.check(); try engine.fm.copyItem(at: generated, to: output)
            }
        case .archive:
            try withTemporaryFolder(engine) { temp in
                let extracted = temp.appendingPathComponent("contents")
                try engine.fm.createDirectory(at: extracted, withIntermediateDirectories: true)
                // bsdtar's default extraction policy rejects absolute paths, '..',
                // and writes through archive-created symlinks. Never pass -P.
                try engine.process("/usr/bin/tar", ["-xf", input.path, "-C", extracted.path, "--no-same-owner", "--no-same-permissions", "--safe-writes"], timeout: 300)
                try engine.check(); progress(0.5)
                let generated = temp.appendingPathComponent("converted." + format)
                if format == "zip" { try engine.process("/usr/bin/ditto", ["-c", "-k", "--norsrc", extracted.path, generated.path], timeout: 300) }
                else { try engine.process("/usr/bin/tar", [format == "tar" ? "-cf" : "-czf", generated.path, "-C", extracted.path, "."], timeout: 300) }
                try engine.check(); try engine.fm.copyItem(at: generated, to: output)
            }
        default: throw OrbitError("Формат не поддерживается.")
        }
        progress(1); return output
    }
    static func withTemporaryFolder(_ engine: ConversionEngine, _ body: (URL) throws -> Void) throws {
        let temp = engine.fm.temporaryDirectory.appendingPathComponent("orbit-" + UUID().uuidString)
        try engine.fm.createDirectory(at: temp, withIntermediateDirectories: true)
        defer { try? engine.fm.removeItem(at: temp) }; try body(temp)
    }
    static func parseTable(_ input: String, separator: Character) throws -> [[String]] {
        var chars = Array(input.hasPrefix("\u{feff}") ? String(input.dropFirst()) : input)
        // Normalise only row separators outside quoted cells; embedded newlines survive.
        var rows: [[String]] = [], row: [String] = [], field = "", quoted = false, i = 0
        while i < chars.count {
            let c = chars[i]
            if quoted {
                if c == "\"" {
                    if i+1 < chars.count && chars[i+1] == "\"" { field.append("\""); i += 1 } else { quoted = false }
                } else { field.append(c) }
            } else if c == "\"" && field.isEmpty { quoted = true }
            else if c == separator { row.append(field); field = "" }
            else if c == "\n" || c == "\r" || c == "\r\n" {
                row.append(field); rows.append(row); row = []; field = ""
                if c == "\r" && i+1 < chars.count && chars[i+1] == "\n" { i += 1 }
            } else { field.append(c) }
            i += 1
        }
        guard !quoted else { throw OrbitError("В таблице не закрыта кавычка.") }
        if !field.isEmpty || !row.isEmpty { row.append(field); rows.append(row) }
        guard !rows.isEmpty else { throw OrbitError("Таблица пуста.") }
        chars.removeAll(); return rows
    }
    static func subtitles(_ input: String, format: String) throws -> String {
        let lines = input.replacingOccurrences(of: "\r\n", with: "\n").replacingOccurrences(of: "\r", with: "\n").components(separatedBy: "\n")
        let regex = try NSRegularExpression(pattern: #"((?:\d{2}:)?\d{2}:\d{2}[.,]\d{3})\s*-->\s*((?:\d{2}:)?\d{2}:\d{2}[.,]\d{3})"#)
        var cues: [(String,String,String)] = []; var i = 0
        while i < lines.count {
            let line = lines[i]
            if let match = regex.firstMatch(in: line, range: NSRange(line.startIndex..., in: line)), let r1 = Range(match.range(at: 1), in: line), let r2 = Range(match.range(at: 2), in: line) {
                var a = String(line[r1]).replacingOccurrences(of: ",", with: "."), b = String(line[r2]).replacingOccurrences(of: ",", with: ".")
                if a.filter({ $0 == ":" }).count == 1 { a = "00:" + a }; if b.filter({ $0 == ":" }).count == 1 { b = "00:" + b }
                i += 1; var content: [String] = []
                while i < lines.count && !lines[i].trimmingCharacters(in: .whitespaces).isEmpty { content.append(lines[i]); i += 1 }
                cues.append((a,b,content.joined(separator: "\n")))
            }
            i += 1
        }
        guard !cues.isEmpty else { throw OrbitError("Не удалось найти временные метки субтитров.") }
        if format == "txt" { return cues.map { $0.2.replacingOccurrences(of: "<[^>]+>", with: "", options: .regularExpression) }.joined(separator: "\n") + "\n" }
        return (format == "vtt" ? "WEBVTT\n\n" : "") + cues.enumerated().map { index, cue in
            let a = format == "srt" ? cue.0.replacingOccurrences(of: ".", with: ",") : cue.0
            let b = format == "srt" ? cue.1.replacingOccurrences(of: ".", with: ",") : cue.1
            return (format == "srt" ? "\(index+1)\n" : "") + a + " --> " + b + "\n" + cue.2 + "\n"
        }.joined(separator: "\n")
    }
}
