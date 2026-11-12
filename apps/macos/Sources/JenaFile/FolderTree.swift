import AppKit
import JenaFileKit

/// FileZilla-style folder tree above a file list: folders only, from "/", loaded
/// lazily as they open. Paths are POSIX for both panes (local and remote).
@MainActor
final class FolderTree: NSView, NSOutlineViewDataSource, NSOutlineViewDelegate {
    final class Node {
        let path: String
        let name: String
        /// nil = not listed yet (shown as openable).
        var children: [Node]?
        init(path: String, name: String) { self.path = path; self.name = name }
    }

    /// Subfolder names of a folder.
    private let load: @MainActor (String) async throws -> [String]
    private var root = Node(path: "/", name: "/")
    let outline = NSOutlineView()
    private let scroll = NSScrollView()
    /// Selection made by code (following the list) must not open the folder again.
    private var following = false
    private var revealToken = 0
    /// The user picked a folder.
    var onSelect: ((String) -> Void)?

    init(load: @escaping @MainActor (String) async throws -> [String]) {
        self.load = load
        super.init(frame: .zero)
        let col = NSTableColumn(identifier: .init("folder"))
        outline.addTableColumn(col)
        outline.outlineTableColumn = col
        outline.headerView = nil
        outline.dataSource = self
        outline.delegate = self
        outline.style = .plain
        outline.autoresizesOutlineColumn = true
        scroll.documentView = outline
        scroll.hasVerticalScroller = true
        scroll.hasHorizontalScroller = true
        scroll.translatesAutoresizingMaskIntoConstraints = false
        addSubview(scroll)
        NSLayoutConstraint.activate([
            scroll.topAnchor.constraint(equalTo: topAnchor),
            scroll.bottomAnchor.constraint(equalTo: bottomAnchor),
            scroll.leadingAnchor.constraint(equalTo: leadingAnchor),
            scroll.trailingAnchor.constraint(equalTo: trailingAnchor),
        ])
    }

    required init?(coder: NSCoder) { fatalError() }

    /// Forget everything (new connection, disconnect, hidden files toggled).
    func reset() {
        revealToken += 1
        root = Node(path: "/", name: "/")
        outline.reloadData()
    }

    /// Folder of the row that was right-clicked (or the selected one).
    var clickedPath: String? {
        let row = outline.clickedRow >= 0 ? outline.clickedRow : outline.selectedRow
        return (outline.item(atRow: row) as? Node)?.path
    }

    /// Siblings of `path` known to the tree (for rename checks).
    func siblingNames(of path: String) -> [String] {
        node(at: RemotePath.parent(path))?.children?.map(\.name) ?? []
    }

    /// The list just showed `path`: keep its subfolders in the tree in step.
    func update(_ path: String, folders: [String]) {
        guard let n = node(at: path) else { return }
        merge(n, folders)
        outline.reloadItem(n, reloadChildren: true)
    }

    /// Lists `path` again (after a rename inside it).
    func reload(_ path: String) async {
        guard let n = node(at: path) else { return }
        guard let names = try? await load(path) else { return }
        merge(n, names)
        outline.reloadItem(n, reloadChildren: true)
    }

    /// Open the tree down to `path` and select it, loading folders on the way.
    func reveal(_ path: String) async {
        revealToken += 1
        let token = revealToken
        if outline.numberOfRows == 0 { outline.reloadData() }
        var n = root
        for name in path.split(separator: "/").map(String.init) {
            if n.children == nil {
                let names = (try? await load(n.path)) ?? []
                guard token == revealToken else { return }
                merge(n, names)
                outline.reloadItem(n, reloadChildren: true)
            }
            // Hidden or unlistable on the way (e.g. no access to "/"): show it anyway.
            if !(n.children ?? []).contains(where: { $0.name == name }) {
                merge(n, (n.children ?? []).map(\.name) + [name])
                outline.reloadItem(n, reloadChildren: true)
            }
            outline.expandItem(n)
            n = n.children!.first { $0.name == name }!
        }
        let row = outline.row(forItem: n)
        guard row >= 0 else { return }
        following = true
        outline.selectRowIndexes([row], byExtendingSelection: false)
        following = false
        outline.scrollRowToVisible(row)
    }

    private func node(at path: String) -> Node? {
        var n = root
        for name in path.split(separator: "/") {
            guard let next = n.children?.first(where: { $0.name == name }) else { return nil }
            n = next
        }
        return n
    }

    /// Keeps the nodes (and their loaded subtrees) whose names stay.
    private func merge(_ n: Node, _ names: [String]) {
        let old = Dictionary((n.children ?? []).map { ($0.name, $0) }, uniquingKeysWith: { a, _ in a })
        n.children = Set(names).sorted { $0.localizedCaseInsensitiveCompare($1) == .orderedAscending }.map { name in
            old[name] ?? Node(path: RemotePath.join(n.path, name), name: name)
        }
    }

    // MARK: outline

    func outlineView(_ outlineView: NSOutlineView, numberOfChildrenOfItem item: Any?) -> Int {
        guard let n = item as? Node else { return 1 }   // the root "/"
        return n.children?.count ?? 0
    }

    func outlineView(_ outlineView: NSOutlineView, child index: Int, ofItem item: Any?) -> Any {
        guard let n = item as? Node else { return root }
        return n.children![index]
    }

    func outlineView(_ outlineView: NSOutlineView, isItemExpandable item: Any) -> Bool {
        guard let n = item as? Node else { return false }
        return n.children.map { !$0.isEmpty } ?? true
    }

    /// First open of a folder: list it, then open it.
    func outlineView(_ outlineView: NSOutlineView, shouldExpandItem item: Any) -> Bool {
        guard let n = item as? Node, n.children == nil else { return true }
        Task {
            let names = (try? await load(n.path)) ?? []
            if n.children == nil { merge(n, names) }
            outline.reloadItem(n, reloadChildren: true)
            if !(n.children ?? []).isEmpty { outline.expandItem(n) }
        }
        return false
    }

    func outlineView(_ outlineView: NSOutlineView, viewFor tableColumn: NSTableColumn?, item: Any) -> NSView? {
        guard let n = item as? Node else { return nil }
        let cell = FileTable.cell(outlineView, "name", owner: self)
        FileTable.setName(cell, n.name, isDir: true)
        return cell
    }

    func outlineViewSelectionDidChange(_ notification: Notification) {
        guard !following, let n = outline.item(atRow: outline.selectedRow) as? Node else { return }
        onSelect?(n.path)
    }
}
