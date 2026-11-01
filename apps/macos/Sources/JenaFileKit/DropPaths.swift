import AppKit

/// Paths carried by a drag: Finder files (file URLs) or remote rows (plain path strings).
public enum DropPaths {
    public static func read(_ pasteboard: NSPasteboard) -> [String] {
        // readObjects returns an empty array (not nil) when there are no file URLs,
        // so check emptiness before falling back to strings.
        let urls = pasteboard.readObjects(forClasses: [NSURL.self],
                                          options: [.urlReadingFileURLsOnly: true]) as? [URL] ?? []
        if !urls.isEmpty { return urls.map(\.path) }
        let strings = pasteboard.readObjects(forClasses: [NSString.self], options: nil) as? [String] ?? []
        return strings.flatMap { $0.split(separator: "\n").map(String.init) }.filter { !$0.isEmpty }
    }
}
