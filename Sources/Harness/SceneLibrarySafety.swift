import Foundation

/// Keeps the Library index safe when more than one Idlesse process writes it,
/// and makes every removal recoverable.
///
/// Each store rewrites the whole index from its in-memory catalog, and a
/// development build, a smoke test or a second copy of the app can hold an
/// older catalog than the file. Writes therefore take an exclusive lock, and
/// when the file changed since this store last read or wrote it, only this
/// store's own changes are replayed onto the file. Any write that drops entries
/// first copies the previous index into Backups, notes who removed what in
/// removals.log, and keeps the entries in Removed.json for restoring.
extension SceneLibraryStore {
    struct RemovedEntry: Codable, Equatable {
        var entry: Entry
        var favorite: Bool
        var recent: Date?
        var collectionIDs: [String]
        var removedAt: Date
    }

    static let keptBackups = 30
    static let keptRemovedEntries = 100
    static let maxRemovalLogBytes = 1_048_576

    /// The Library index this process uses; `IDLESSE_LIBRARY_INDEX` points a test or UI probe at a scratch Library.
    static var defaultIndexURL: URL {
        if let override = ProcessInfo.processInfo.environment["IDLESSE_LIBRARY_INDEX"], !override.isEmpty {
            return URL(fileURLWithPath: (override as NSString).expandingTildeInPath)
        }
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        return support.appendingPathComponent("Idlesse/Library/index.json")
    }

    var backupsFolder: URL { file.deletingLastPathComponent().appendingPathComponent("Backups", isDirectory: true) }
    var removalLog: URL { file.deletingLastPathComponent().appendingPathComponent("removals.log") }
    var removedFile: URL { file.deletingLastPathComponent().appendingPathComponent("Removed.json") }

    // MARK: Concurrent writers

    func withIndexLock<T>(_ body: () throws -> T) throws -> T {
        try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        let descriptor = open(file.path + ".lock", O_CREAT | O_RDWR | O_CLOEXEC, 0o644)
        guard descriptor >= 0 else { throw Self.libraryFailure("The Library index could not be locked.") }
        defer { close(descriptor) }
        guard flock(descriptor, LOCK_EX) == 0 else { throw Self.libraryFailure("The Library index could not be locked.") }
        defer { flock(descriptor, LOCK_UN) }
        return try body()
    }

    /// The index as it is on disk now, and its bytes for a backup.
    func readIndex() throws -> (Catalog, Data?) {
        guard FileManager.default.fileExists(atPath: file.path) else { return (Catalog(), nil) }
        let attributes = try FileManager.default.attributesOfItem(atPath: file.path)
        guard ((attributes[.size] as? NSNumber)?.intValue ?? 0) <= Self.maxIndexBytes else {
            throw Self.libraryFailure("The Library index is too large.")
        }
        let data = try Data(contentsOf: file)
        let decoded: Catalog
        do { decoded = try JSONDecoder().decode(Catalog.self, from: data) } catch {
            throw Self.libraryFailure("The Library index on disk is unreadable, so it was left untouched.")
        }
        guard (1...Self.catalogVersion).contains(decoded.version) else {
            throw Self.libraryFailure("This Library index was written by a newer Idlesse version.")
        }
        return (decoded, data)
    }

    /// Replays the change from `base` to `proposed` onto `disk`, the index another writer left.
    /// Removals elsewhere win over edits here; additions on both sides are kept.
    static func rebase(_ proposed: Catalog, from base: Catalog, onto disk: Catalog) -> Catalog {
        var result = disk
        result.entries = merge(proposed.entries, base.entries, disk.entries, id: \.id)
        result.sources = merge(proposed.sources, base.sources, disk.sources, id: \.id)
        result.collections = merge(proposed.collections, base.collections, disk.collections, id: \.id)
        result.favorites = disk.favorites
            .subtracting(base.favorites.subtracting(proposed.favorites))
            .union(proposed.favorites.subtracting(base.favorites))
        for key in base.recent.keys where proposed.recent[key] == nil { result.recent.removeValue(forKey: key) }
        for (key, date) in proposed.recent where base.recent[key] != date { result.recent[key] = date }

        let sourceIDs = Set(result.sources.map(\.id))
        result.entries.removeAll { entry in entry.sourceID.map { !sourceIDs.contains($0) } ?? false }
        // Built-in scenes appear in favorites and recents without an entry, so only
        // references to entries that existed somewhere and no longer do are dropped.
        let kept = Set(result.entries.map(\.id))
        let gone = Set((base.entries + disk.entries + proposed.entries).map(\.id)).subtracting(kept)
        result.favorites.subtract(gone)
        for key in gone { result.recent.removeValue(forKey: key) }
        for index in result.collections.indices { result.collections[index].sceneIDs.removeAll { gone.contains($0) } }
        while result.recent.count > 256, let oldest = result.recent.min(by: { $0.value < $1.value })?.key {
            result.recent.removeValue(forKey: oldest)
        }
        return result
    }

    private static func merge<T: Equatable>(_ proposed: [T], _ base: [T], _ disk: [T], id: (T) -> String) -> [T] {
        let before = Dictionary(base.map { (id($0), $0) }, uniquingKeysWith: { first, _ in first })
        let now = Set(proposed.map(id))
        var result = disk.filter { before[id($0)] == nil || now.contains(id($0)) }
        for item in proposed where before[id(item)] != item {
            if let index = result.firstIndex(where: { id($0) == id(item) }) {
                result[index] = item
            } else if before[id(item)] == nil {
                result.append(item)
            }
        }
        return result
    }

    // MARK: Removals

    /// Called under the index lock before a write that drops `removed` from `previous`.
    func journalRemoval(_ removed: [Entry], previous: Catalog, previousData: Data?) {
        let manager = FileManager.default
        let now = Date()
        let process = ProcessInfo.processInfo
        if let previousData, (try? manager.createDirectory(at: backupsFolder, withIntermediateDirectories: true)) != nil {
            let stamp = Self.stampFormatter.string(from: now)
            try? previousData.write(to: backupsFolder.appendingPathComponent("index-\(stamp)-\(process.processIdentifier).json"), options: .atomic)
            let backups = ((try? manager.contentsOfDirectory(atPath: backupsFolder.path)) ?? [])
                .filter { $0.hasPrefix("index-") && $0.hasSuffix(".json") }.sorted()
            for name in backups.dropLast(Self.keptBackups) {
                try? manager.removeItem(at: backupsFolder.appendingPathComponent(name))
            }
        }

        let titles = removed.map { "\($0.title) [\($0.id)]" }.joined(separator: ", ")
        let arguments = process.arguments.dropFirst().joined(separator: " ")
        let line = "\(ISO8601DateFormatter().string(from: now)) pid=\(process.processIdentifier) \(process.processName)"
            + (arguments.isEmpty ? "" : " args=\(arguments)") + " removed \(removed.count): \(titles)\n"
        if let size = (try? manager.attributesOfItem(atPath: removalLog.path))?[.size] as? NSNumber, size.intValue > Self.maxRemovalLogBytes {
            let rotated = removalLog.appendingPathExtension("1")
            try? manager.removeItem(at: rotated)
            try? manager.moveItem(at: removalLog, to: rotated)
        }
        if let handle = try? FileHandle(forWritingTo: removalLog) {
            handle.seekToEndOfFile()
            handle.write(Data(line.utf8))
            try? handle.close()
        } else {
            try? Data(line.utf8).write(to: removalLog)
        }

        var records = recentlyRemoved()
        let ids = Set(removed.map(\.id))
        records.removeAll { ids.contains($0.entry.id) }
        records.insert(contentsOf: removed.map { entry in
            RemovedEntry(entry: entry, favorite: previous.favorites.contains(entry.id), recent: previous.recent[entry.id],
                         collectionIDs: previous.collections.filter { $0.sceneIDs.contains(entry.id) }.map(\.id), removedAt: now)
        }, at: 0)
        writeRemoved(Array(records.prefix(Self.keptRemovedEntries)))
    }

    /// Newest first.
    func recentlyRemoved() -> [RemovedEntry] {
        guard let data = try? Data(contentsOf: removedFile) else { return [] }
        return (try? JSONDecoder().decode([RemovedEntry].self, from: data)) ?? []
    }

    private func writeRemoved(_ records: [RemovedEntry]) {
        guard let data = try? JSONEncoder().encode(records) else { return }
        try? data.write(to: removedFile, options: .atomic)
    }

    /// Puts a removed entry back with its favorite, recent date and the collections that still exist.
    @discardableResult
    func restoreRemoved(_ id: String) throws -> Entry {
        guard let record = recentlyRemoved().first(where: { $0.entry.id == id }) else {
            throw Self.libraryFailure("That wallpaper is no longer in Recently Removed.")
        }
        var next = catalog
        if !next.entries.contains(where: { $0.id == id }) {
            if let sourceID = record.entry.sourceID, !next.sources.contains(where: { $0.id == sourceID }) {
                throw Self.libraryFailure("Its Source was removed. Add that folder again to bring it back.")
            }
            next.entries.append(record.entry)
            if record.favorite { next.favorites.insert(id) }
            if let recent = record.recent { next.recent[id] = recent }
            while next.recent.count > 256, let oldest = next.recent.min(by: { $0.value < $1.value })?.key {
                next.recent.removeValue(forKey: oldest)
            }
            for index in next.collections.indices where record.collectionIDs.contains(next.collections[index].id) {
                if !next.collections[index].sceneIDs.contains(id), next.collections[index].sceneIDs.count < 256 {
                    next.collections[index].sceneIDs.append(id)
                }
            }
            try commitCatalog(next)
        }
        writeRemoved(recentlyRemoved().filter { $0.entry.id != id })
        return record.entry
    }

    private static let stampFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(identifier: "UTC")
        formatter.dateFormat = "yyyyMMdd-HHmmss-SSS"
        return formatter
    }()
}
