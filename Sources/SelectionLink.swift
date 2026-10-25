import Foundation

/// A Finder extension can pass a selection without trying to open/read files
/// inside its sandbox. Orbit still asks the user to choose a conversion.
enum SelectionLink {
    static let scheme = "orbit-convert"
    static func make(_ files: [URL]) -> URL? {
        guard !files.isEmpty, files.count <= 1000, files.allSatisfy({ $0.isFileURL }) else { return nil }
        var link = URLComponents()
        link.scheme = scheme; link.host = "selection"
        link.queryItems = files.map { URLQueryItem(name: "file", value: $0.absoluteString) }
        return link.url
    }
    static func files(from incoming: [URL]) -> [URL] {
        var files: [URL] = []
        for url in incoming {
            if url.isFileURL { files.append(url); continue }
            guard url.scheme == scheme, url.host == "selection", url.absoluteString.utf8.count <= 1_048_576,
                  let items = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems,
                  items.count <= 1000 else { continue }
            files += items.compactMap { item in
                guard item.name == "file", let value = item.value, let file = URL(string: value), file.isFileURL,
                      file.host == nil || file.host == "" || file.host == "localhost" else { return nil }
                return file
            }
        }
        return Array(files.prefix(1000))
    }
}
