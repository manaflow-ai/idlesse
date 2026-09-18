import Foundation

/// An index of references. Original media stays where the user put it.
final class SceneLibraryStore {
    static let catalogVersion = 2
    static let maxBookmarkBytes = 16_384

    struct Entry: Codable, Equatable, Sendable {
        var id: String
        var title: String
        var bookmark: Data?
        var catalogID: String?
        var sourceID: String?
        var relativeMediaPath: String?
        var relativePosterPath: String?
        var series: String?
        var character: String?
        var variant: String?
        var tags: [String] = []
        var mediaType: String?
        var width: Int?
        var height: Int?
        var fps: Double?
        var duration: Double?
        var provenance: [String: String]?
        var availability: EntryAvailability = .present
        var observation: ReconciliationObservation?

        /// Older individually imported entries have only a bookmark. Read its
        /// embedded path without resolving/mounting the source or decoding media.
        var inferredMediaType: String? {
            if let mediaType { return mediaType }
            let bookmarkPath = bookmark.flatMap {
                URL.resourceValues(forKeys: [.pathKey], fromBookmarkData: $0)?.path
            }
            let path = relativeMediaPath ?? bookmarkPath ?? ""
            switch (path as NSString).pathExtension.lowercased() {
            case "mp4", "mov", "m4v", "webm", "mkv", "avi": return "video"
            case "idlesse": return "scene"
            case "jpg", "jpeg", "png", "heic", "heif", "webp", "tif", "tiff", "bmp", "avif": return "image"
            default: return nil
            }
        }

        init(id: String, title: String, bookmark: Data? = nil, catalogID: String? = nil,
             sourceID: String? = nil, relativeMediaPath: String? = nil,
             relativePosterPath: String? = nil, series: String? = nil,
             character: String? = nil, variant: String? = nil, tags: [String] = [],
             mediaType: String? = nil, width: Int? = nil, height: Int? = nil,
             fps: Double? = nil, duration: Double? = nil,
             provenance: [String: String]? = nil,
             availability: EntryAvailability = .present,
             observation: ReconciliationObservation? = nil) {
            self.id = id
            self.title = title
            self.bookmark = bookmark
            self.catalogID = catalogID
            self.sourceID = sourceID
            self.relativeMediaPath = relativeMediaPath
            self.relativePosterPath = relativePosterPath
            self.series = series
            self.character = character
            self.variant = variant
            self.tags = tags
            self.mediaType = mediaType
            self.width = width
            self.height = height
            self.fps = fps
            self.duration = duration
            self.provenance = provenance
            self.availability = availability
            self.observation = observation
        }

        enum CodingKeys: String, CodingKey {
            case id, title, bookmark, catalogID, sourceID, relativeMediaPath, relativePosterPath
            case series, character, variant, tags, mediaType, width, height, fps, duration, provenance
            case availability, observation
        }
        init(from decoder: Decoder) throws {
            let values = try decoder.container(keyedBy: CodingKeys.self)
            id = try values.decode(String.self, forKey: .id)
            title = try values.decode(String.self, forKey: .title)
            bookmark = try values.decodeIfPresent(Data.self, forKey: .bookmark)
            catalogID = try values.decodeIfPresent(String.self, forKey: .catalogID)
            sourceID = try values.decodeIfPresent(String.self, forKey: .sourceID)
            relativeMediaPath = try values.decodeIfPresent(String.self, forKey: .relativeMediaPath)
            relativePosterPath = try values.decodeIfPresent(String.self, forKey: .relativePosterPath)
            series = try values.decodeIfPresent(String.self, forKey: .series)
            character = try values.decodeIfPresent(String.self, forKey: .character)
            variant = try values.decodeIfPresent(String.self, forKey: .variant)
            tags = try values.decodeIfPresent([String].self, forKey: .tags) ?? []
            mediaType = try values.decodeIfPresent(String.self, forKey: .mediaType)
            width = try values.decodeIfPresent(Int.self, forKey: .width)
            height = try values.decodeIfPresent(Int.self, forKey: .height)
            fps = try values.decodeIfPresent(Double.self, forKey: .fps)
            duration = try values.decodeIfPresent(Double.self, forKey: .duration)
            provenance = try values.decodeIfPresent([String: String].self, forKey: .provenance)
            availability = try values.decodeIfPresent(EntryAvailability.self, forKey: .availability) ?? .present
            observation = try values.decodeIfPresent(ReconciliationObservation.self, forKey: .observation)
        }
        func encode(to encoder: Encoder) throws {
            var values = encoder.container(keyedBy: CodingKeys.self)
            try values.encode(id, forKey: .id)
            try values.encode(title, forKey: .title)
            try values.encodeIfPresent(bookmark, forKey: .bookmark)
            try values.encodeIfPresent(catalogID, forKey: .catalogID)
            try values.encodeIfPresent(sourceID, forKey: .sourceID)
            try values.encodeIfPresent(relativeMediaPath, forKey: .relativeMediaPath)
            try values.encodeIfPresent(relativePosterPath, forKey: .relativePosterPath)
            try values.encodeIfPresent(series, forKey: .series)
            try values.encodeIfPresent(character, forKey: .character)
            try values.encodeIfPresent(variant, forKey: .variant)
            if !tags.isEmpty { try values.encode(tags, forKey: .tags) }
            try values.encodeIfPresent(mediaType, forKey: .mediaType)
            try values.encodeIfPresent(width, forKey: .width)
            try values.encodeIfPresent(height, forKey: .height)
            try values.encodeIfPresent(fps, forKey: .fps)
            try values.encodeIfPresent(duration, forKey: .duration)
            try values.encodeIfPresent(provenance, forKey: .provenance)
            if availability != .present { try values.encode(availability, forKey: .availability) }
            try values.encodeIfPresent(observation, forKey: .observation)
        }
    }

    struct SourceRoot: Codable, Equatable, Sendable {
        var id: String
        var name: String
        var bookmark: Data
        var catalogMetadata: [String: String]?

        init(id: String = UUID().uuidString, name: String, bookmark: Data,
             catalogMetadata: [String: String]? = nil) {
            self.id = id
            self.name = name
            self.bookmark = bookmark
            self.catalogMetadata = catalogMetadata
        }
    }

    /// One entry to add beneath an already authorized source root.
    struct SourceEntry: Equatable, Sendable {
        var relativeMediaPath: String
        var title: String?
        var catalogID: String?
        var relativePosterPath: String?
        var series: String?
        var character: String?
        var variant: String?
        var tags: [String] = []
        var mediaType: String?
        var width: Int?
        var height: Int?
        var fps: Double?
        var duration: Double?
        var provenance: [String: String]?
        var observation: ReconciliationObservation?

        init(relativeMediaPath: String, title: String? = nil, catalogID: String? = nil,
             relativePosterPath: String? = nil, series: String? = nil,
             character: String? = nil, variant: String? = nil, tags: [String] = [],
             mediaType: String? = nil, width: Int? = nil, height: Int? = nil,
             fps: Double? = nil, duration: Double? = nil,
             provenance: [String: String]? = nil,
             observation: ReconciliationObservation? = nil) {
            self.relativeMediaPath = relativeMediaPath
            self.title = title
            self.catalogID = catalogID
            self.relativePosterPath = relativePosterPath
            self.series = series
            self.character = character
            self.variant = variant
            self.tags = tags
            self.mediaType = mediaType
            self.width = width
            self.height = height
            self.fps = fps
            self.duration = duration
            self.provenance = provenance
            self.observation = observation
        }
    }

    /// Owns a security-scoped grant for exactly as long as a caller uses its URL.
    final class Access: @unchecked Sendable {
        let url: URL
        let sourceID: String?
        private var scopeURL: URL?
        private var started = false

        fileprivate init(url: URL, scopeURL: URL, sourceID: String?) {
            self.url = url
            self.scopeURL = scopeURL
            self.sourceID = sourceID
            started = scopeURL.startAccessingSecurityScopedResource()
        }
        func close() {
            if started { scopeURL?.stopAccessingSecurityScopedResource() }
            started = false
            scopeURL = nil
        }
        deinit { close() }
    }

    struct Playback: Codable, Equatable {
        var minutes: Int = 30
        var shuffle: Bool = false
        var startMinute: Int?
        var endMinute: Int?
        // Calendar weekday numbers; nil preserves legacy daily schedules.
        var weekdays: Set<Int>?
        func contains(_ minute: Int, weekday: Int = 1) -> Bool {
            guard let start = startMinute, let end = endMinute else { return false }
            let owner = start > end && minute < end ? (weekday == 1 ? 7 : weekday - 1) : weekday
            guard weekdays?.contains(owner) ?? true else { return false }
            return start < end ? minute >= start && minute < end : minute >= start || minute < end
        }
    }
    struct Collection: Codable, Equatable {
        var id: String = UUID().uuidString
        var name: String
        var sceneIDs: [String] = []
        var playback: Playback?
    }
    struct Catalog: Codable, Equatable {
        var version: Int = SceneLibraryStore.catalogVersion
        var entries: [Entry] = []
        var sources: [SourceRoot] = []
        var favorites: Set<String> = []
        var recent: [String: Date] = [:]
        var collections: [Collection] = []
        init() {}
        enum CodingKeys: String, CodingKey { case version, entries, sources, favorites, recent, collections }
        init(from decoder: Decoder) throws {
            let values = try decoder.container(keyedBy: CodingKeys.self)
            version = try values.decodeIfPresent(Int.self, forKey: .version) ?? 1
            entries = try values.decode([Entry].self, forKey: .entries)
            sources = try values.decodeIfPresent([SourceRoot].self, forKey: .sources) ?? []
            favorites = try values.decode(Set<String>.self, forKey: .favorites)
            recent = try values.decode([String: Date].self, forKey: .recent)
            collections = try values.decodeIfPresent([Collection].self, forKey: .collections) ?? []
        }
    }

    private(set) var catalog = Catalog()
    let file: URL

    init(file: URL) throws {
        self.file = file
        guard FileManager.default.fileExists(atPath: file.path) else { return }
        let decoded = try JSONDecoder().decode(Catalog.self, from: Data(contentsOf: file))
        guard (1...Self.catalogVersion).contains(decoded.version) else {
            throw failure("This Library index was written by a newer Idlesse version.")
        }
        try validateCatalog(decoded)
        catalog = decoded
    }

    /// Compatibility resolver. Call `access(_:)` while reading source-backed media.
    func resolve(_ entry: Entry) throws -> URL { try access(entry).url }

    /// Captures reference data without resolving bookmarks or reading the filesystem.
    /// Workers may resolve this value without touching the mutable catalog.
    struct AccessRequest: Sendable {
        let entry: Entry
        let source: SourceRoot?
        func open() throws -> Access { try SceneLibraryStore.resolve(entry, source: source) }
        func openPoster() throws -> Access? {
            guard entry.availability == .present, let source, let relative = entry.relativePosterPath else { return nil }
            return try SceneLibraryStore.access(relativePath: relative, source: source)
        }
    }

    func accessRequest(_ entry: Entry) -> AccessRequest {
        AccessRequest(entry: entry, source: catalog.sources.first { $0.id == entry.sourceID })
    }
    func access(_ entry: Entry) throws -> Access { try accessRequest(entry).open() }
    func accessPoster(_ entry: Entry) throws -> Access? { try accessRequest(entry).openPoster() }

    private static func resolve(_ entry: Entry, source: SourceRoot?) throws -> Access {
        guard entry.availability == .present else {
            throw libraryFailure("This Library item is missing from its Source. Rescan the Source to reconcile it.")
        }
        if let bookmark = entry.bookmark {
            var stale = false
            let url: URL
            do {
                url = try URL(resolvingBookmarkData: bookmark, options: [.withSecurityScope, .withoutUI],
                              relativeTo: nil, bookmarkDataIsStale: &stale)
            } catch {
                url = try URL(resolvingBookmarkData: bookmark, options: [.withoutUI],
                              relativeTo: nil, bookmarkDataIsStale: &stale)
            }
            return Access(url: url, scopeURL: url, sourceID: nil)
        }
        guard let source, let relative = entry.relativeMediaPath else {
            throw libraryFailure("This Library entry has no usable source reference.")
        }
        return try access(relativePath: relative, source: source)
    }

    func accessSource(_ sourceID: String) throws -> Access {
        guard let source = catalog.sources.first(where: { $0.id == sourceID }) else { throw failure("Source no longer exists.") }
        return try Self.accessSourceRoot(source)
    }

    @discardableResult func add(_ url: URL, title: String? = nil) throws -> Entry {
        if let existing = catalog.entries.first(where: {
            guard $0.bookmark != nil else { return false }
            return (try? resolve($0).standardizedFileURL) == url.standardizedFileURL
        }) { return existing }
        let accessed = url.startAccessingSecurityScopedResource()
        defer { if accessed { url.stopAccessingSecurityScopedResource() } }
        let bookmark = try url.bookmarkData(options: [.withSecurityScope], includingResourceValuesForKeys: nil, relativeTo: nil)
        guard bookmark.count <= Self.maxBookmarkBytes else { throw failure("That file's access reference is too large.") }
        let entry = Entry(id: UUID().uuidString,
                          title: Self.bounded(title ?? url.deletingPathExtension().lastPathComponent, bytes: 1024),
                          bookmark: bookmark)
        var next = catalog
        next.entries.append(entry)
        try save(next)
        return entry
    }

    @discardableResult
    func addSource(_ url: URL, name: String? = nil, catalogMetadata: [String: String]? = nil,
                   entries: [SourceEntry] = []) throws -> SourceRoot {
        let root = url.standardizedFileURL
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: root.path, isDirectory: &isDirectory), isDirectory.boolValue else {
            throw failure("Choose an available folder for this Source.")
        }
        if let existing = catalog.sources.first(where: { source in
            guard let access = try? Self.accessSourceRoot(source) else { return false }
            return access.url.resolvingSymlinksInPath().standardizedFileURL == root.resolvingSymlinksInPath().standardizedFileURL
        }) {
            if !entries.isEmpty { _ = try addSourceEntries(existing.id, entries) }
            return catalog.sources.first(where: { $0.id == existing.id }) ?? existing
        }
        let accessed = root.startAccessingSecurityScopedResource()
        defer { if accessed { root.stopAccessingSecurityScopedResource() } }
        let bookmark = try root.bookmarkData(options: [.withSecurityScope], includingResourceValuesForKeys: nil, relativeTo: nil)
        guard bookmark.count <= Self.maxBookmarkBytes else { throw failure("That folder's access reference is too large.") }
        let source = SourceRoot(name: Self.bounded(name ?? root.lastPathComponent, bytes: 120),
                                bookmark: bookmark, catalogMetadata: catalogMetadata)
        var next = catalog
        next.sources.append(source)
        let newEntries = try makeEntries(entries, sourceID: source.id, existing: next.entries)
        next.entries.append(contentsOf: newEntries)
        try save(next)
        return source
    }

    @discardableResult
    func addSourceEntries(_ sourceID: String, _ entries: [SourceEntry]) throws -> [Entry] {
        guard catalog.sources.contains(where: { $0.id == sourceID }) else { throw failure("Source no longer exists.") }
        var next = catalog
        let added = try makeEntries(entries, sourceID: sourceID, existing: next.entries)
        next.entries.append(contentsOf: added)
        try save(next)
        return added
    }

    func relinkSource(_ id: String, to url: URL) throws {
        var next = catalog
        guard let index = next.sources.firstIndex(where: { $0.id == id }) else { throw failure("Source no longer exists.") }
        let root = url.standardizedFileURL
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: root.path, isDirectory: &isDirectory), isDirectory.boolValue else {
            throw failure("Choose an available folder for this Source.")
        }
        let accessed = root.startAccessingSecurityScopedResource()
        defer { if accessed { root.stopAccessingSecurityScopedResource() } }
        let bookmark = try root.bookmarkData(options: [.withSecurityScope], includingResourceValuesForKeys: nil, relativeTo: nil)
        guard bookmark.count <= Self.maxBookmarkBytes else { throw failure("That folder's access reference is too large.") }
        next.sources[index].bookmark = bookmark
        try save(next)
    }

    /// Removes source references from the Library index only. Files under the folder stay untouched.
    func removeSource(_ id: String) throws {
        var next = catalog
        guard next.sources.contains(where: { $0.id == id }) else { throw failure("Source no longer exists.") }
        let removed = Set(next.entries.filter { $0.sourceID == id }.map(\.id))
        next.sources.removeAll { $0.id == id }
        next.entries.removeAll { $0.sourceID == id }
        next.favorites.subtract(removed)
        for entryID in removed { next.recent.removeValue(forKey: entryID) }
        for index in next.collections.indices { next.collections[index].sceneIDs.removeAll { removed.contains($0) } }
        try save(next)
    }

    func favorite(_ id: String) throws {
        var next = catalog
        if !next.favorites.insert(id).inserted { next.favorites.remove(id) }
        try save(next)
    }
    func used(_ id: String) throws {
        var next = catalog
        next.recent[id] = Date()
        while next.recent.count > 256, let oldest = next.recent.min(by: { $0.value < $1.value })?.key {
            next.recent.removeValue(forKey: oldest)
        }
        try save(next)
    }
    func restoreRemovedEntry(_ entry: Entry, favorite: Bool, recent: Date?, collectionIDs: [String]) throws {
        guard !catalog.entries.contains(where: { $0.id == entry.id }) else { return }
        var next = catalog
        next.entries.append(entry)
        if favorite { next.favorites.insert(entry.id) }
        if let recent { next.recent[entry.id] = recent }
        for index in next.collections.indices where collectionIDs.contains(next.collections[index].id) {
            if !next.collections[index].sceneIDs.contains(entry.id) { next.collections[index].sceneIDs.append(entry.id) }
        }
        try save(next)
    }
    func remove(_ id: String) throws {
        var next = catalog
        next.entries.removeAll { $0.id == id }
        next.favorites.remove(id)
        next.recent.removeValue(forKey: id)
        for i in next.collections.indices { next.collections[i].sceneIDs.removeAll { $0 == id } }
        try save(next)
    }
    @discardableResult func createCollection(name: String) throws -> Collection {
        let collection = Collection(name: name.trimmingCharacters(in: .whitespacesAndNewlines))
        var next = catalog
        next.collections.append(collection)
        try save(next)
        return collection
    }
    func renameCollection(_ id: String, name: String) throws {
        var next = catalog
        guard let index = next.collections.firstIndex(where: { $0.id == id }) else { throw failure("Collection no longer exists.") }
        next.collections[index].name = name.trimmingCharacters(in: .whitespacesAndNewlines)
        try save(next)
    }
    func removeCollection(_ id: String) throws {
        var next = catalog
        next.collections.removeAll { $0.id == id }
        try save(next)
    }
    func toggleMembership(sceneID: String, collectionID: String) throws {
        var next = catalog
        guard let index = next.collections.firstIndex(where: { $0.id == collectionID }) else { throw failure("Collection no longer exists.") }
        if next.collections[index].sceneIDs.contains(sceneID) {
            next.collections[index].sceneIDs.removeAll { $0 == sceneID }
        } else { next.collections[index].sceneIDs.append(sceneID) }
        try save(next)
    }
    func moveCollection(_ id: String, by offset: Int) throws {
        var next = catalog
        guard let index = next.collections.firstIndex(where: { $0.id == id }),
              [-1, 1].contains(offset) else { throw failure("Select a collection.") }
        let destination = index + offset
        guard next.collections.indices.contains(destination) else { return }
        next.collections.swapAt(index, destination)
        try save(next)
    }
    func moveScene(_ sceneID: String, in collectionID: String, by offset: Int) throws {
        var next = catalog
        guard let collection = next.collections.firstIndex(where: { $0.id == collectionID }),
              let index = next.collections[collection].sceneIDs.firstIndex(of: sceneID),
              [-1, 1].contains(offset) else { throw failure("Select a scene in a collection.") }
        let destination = index + offset
        guard next.collections[collection].sceneIDs.indices.contains(destination) else { return }
        next.collections[collection].sceneIDs.swapAt(index, destination)
        try save(next)
    }
    func setPlayback(_ id: String, _ playback: Playback) throws {
        var next = catalog
        guard let index = next.collections.firstIndex(where: { $0.id == id }) else { throw failure("Collection no longer exists.") }
        next.collections[index].playback = playback
        try save(next)
    }
    /// Daily local-time ranges; overlaps are rejected instead of using hidden priority.
    func scheduledCollection(at date: Date, calendar: Calendar = .current) -> Collection? {
        let parts = calendar.dateComponents([.hour, .minute, .weekday], from: date)
        let minute = (parts.hour ?? 0) * 60 + (parts.minute ?? 0)
        return catalog.collections.first { $0.playback?.contains(minute, weekday: parts.weekday ?? 1) == true }
    }

    static func validatedRelativePath(_ path: String) throws -> String {
        guard !path.isEmpty, path.utf8.count <= 4096, !path.hasPrefix("/"), !path.utf8.contains(0) else {
            throw libraryFailure("Source paths must be relative paths within the authorized folder.")
        }
        let parts = path.split(separator: "/", omittingEmptySubsequences: false)
        guard parts.allSatisfy({ !$0.isEmpty && $0 != "." && $0 != ".." }) else {
            throw libraryFailure("Source paths must stay within the authorized folder.")
        }
        return path
    }

    static func relativePath(from root: URL, to child: URL) throws -> String {
        let base = root.standardizedFileURL.path
        let target = child.standardizedFileURL.path
        let prefix = base == "/" ? "/" : base + "/"
        guard target.hasPrefix(prefix), target.count > prefix.count else {
            throw libraryFailure("The selected item is outside the Source folder.")
        }
        return try validatedRelativePath(String(target.dropFirst(prefix.count)))
    }

    private func makeEntries(_ drafts: [SourceEntry], sourceID: String, existing: [Entry]) throws -> [Entry] {
        var known = Set(existing.compactMap { entry -> String? in
            guard entry.sourceID == sourceID, let path = entry.relativeMediaPath else { return nil }
            return path
        })
        var result: [Entry] = []
        for draft in drafts {
            let path = try Self.validatedRelativePath(draft.relativeMediaPath)
            if known.contains(path) { continue }
            known.insert(path)
            let poster = try draft.relativePosterPath.map(Self.validatedRelativePath)
            let fallback = URL(fileURLWithPath: path).deletingPathExtension().lastPathComponent
            result.append(Entry(id: UUID().uuidString,
                title: Self.bounded(draft.title ?? fallback, bytes: 1024),
                catalogID: draft.catalogID, sourceID: sourceID, relativeMediaPath: path,
                relativePosterPath: poster, series: draft.series, character: draft.character,
                variant: draft.variant, tags: draft.tags, mediaType: draft.mediaType,
                width: draft.width, height: draft.height, fps: draft.fps,
                duration: draft.duration, provenance: draft.provenance,
                availability: .present, observation: draft.observation))
        }
        return result
    }

    private static func access(relativePath: String, source: SourceRoot) throws -> Access {
        let relative = try Self.validatedRelativePath(relativePath)
        let rootAccess = try accessSourceRoot(source)
        let target = rootAccess.url.appendingPathComponent(relative).standardizedFileURL
        guard Self.isDescendant(target, of: rootAccess.url) else {
            throw libraryFailure("Source path escapes the authorized folder.")
        }
        let resolvedRoot = rootAccess.url.resolvingSymlinksInPath().standardizedFileURL
        let resolvedTarget = target.resolvingSymlinksInPath().standardizedFileURL
        guard Self.isDescendant(resolvedTarget, of: resolvedRoot) else {
            throw libraryFailure("Source path resolves outside the authorized folder.")
        }
        return Access(url: target, scopeURL: rootAccess.url, sourceID: source.id)
    }

    private static func accessSourceRoot(_ source: SourceRoot) throws -> Access {
        let root: URL
        do {
            var stale = false
            root = try URL(resolvingBookmarkData: source.bookmark, options: [.withSecurityScope, .withoutUI],
                           relativeTo: nil, bookmarkDataIsStale: &stale).standardizedFileURL
        } catch {
            throw libraryFailure("Source “\(source.name)” is unavailable. Use Relink Source… to choose its folder again.")
        }
        let access = Access(url: root, scopeURL: root, sourceID: source.id)
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: root.path, isDirectory: &isDirectory), isDirectory.boolValue else {
            throw libraryFailure("Source “\(source.name)” is unavailable. Use Relink Source… to choose its folder again.")
        }
        return access
    }

    private static func isDescendant(_ child: URL, of root: URL) -> Bool {
        let base = root.standardizedFileURL.path
        let target = child.standardizedFileURL.path
        let prefix = base == "/" ? "/" : base + "/"
        return target.hasPrefix(prefix) && target.count > prefix.count
    }

    private func validateCatalog(_ value: Catalog) throws {
        guard Set(value.entries.map(\.id)).count == value.entries.count,
              Set(value.sources.map(\.id)).count == value.sources.count
        else { throw failure("The Library index contains duplicate entry or Source identifiers.") }

        let sourceIDs = Set(value.sources.map(\.id))
        for source in value.sources {
            guard !source.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                  source.name.utf8.count <= 120, source.id.utf8.count <= 128,
                  source.bookmark.count <= Self.maxBookmarkBytes,
                  Self.validMetadata(source.catalogMetadata, maxPairs: 32)
            else { throw failure("A Library Source exceeds its limits.") }
        }

        var catalogIDs: Set<String> = []
        for entry in value.entries {
            guard !entry.id.isEmpty, entry.id.utf8.count <= 128,
                  !entry.title.isEmpty, entry.title.utf8.count <= 1024,
                  entry.catalogID.map({ !$0.isEmpty && $0.utf8.count <= 256 }) ?? true,
                  entry.series.map({ $0.utf8.count <= 512 }) ?? true,
                  entry.character.map({ $0.utf8.count <= 512 }) ?? true,
                  entry.variant.map({ $0.utf8.count <= 512 }) ?? true,
                  entry.mediaType.map({ $0.utf8.count <= 64 }) ?? true,
                  entry.tags.count <= 64 && entry.tags.allSatisfy({ !$0.isEmpty && $0.utf8.count <= 128 }),
                  Self.validMetadata(entry.provenance, maxPairs: 32),
                  Self.validDimension(entry.width), Self.validDimension(entry.height),
                  Self.validRate(entry.fps), Self.validDuration(entry.duration),
                  Self.validObservation(entry.observation)
            else { throw failure("A Library entry exceeds its metadata limits.") }

            if let bookmark = entry.bookmark {
                guard entry.availability == .present, bookmark.count <= Self.maxBookmarkBytes,
                      entry.sourceID == nil, entry.relativeMediaPath == nil, entry.relativePosterPath == nil,
                      entry.observation == nil else {
                    throw failure("A Library entry mixes individual and Source references.")
                }
            } else {
                guard let sourceID = entry.sourceID, sourceIDs.contains(sourceID),
                      let relative = entry.relativeMediaPath else {
                    throw failure("A source-backed Library entry references a missing Source.")
                }
                _ = try Self.validatedRelativePath(relative)
                if let poster = entry.relativePosterPath { _ = try Self.validatedRelativePath(poster) }
                if let catalogID = entry.catalogID {
                    let key = sourceID + "\u{0}" + catalogID
                    guard catalogIDs.insert(key).inserted else { throw failure("Catalog IDs must be unique within a Source.") }
                }
            }
        }
        try validateCollections(value)
    }

    private func validateCollections(_ value: Catalog) throws {
        for collection in value.collections {
            guard let settings = collection.playback else { continue }
            guard settings.weekdays.map({ !$0.isEmpty && $0.isSubset(of: Set(1...7)) }) ?? true
            else { throw failure("Choose at least one valid schedule day.") }
            guard [5, 15, 30, 60].contains(settings.minutes),
                  (settings.startMinute == nil && settings.endMinute == nil) ||
                  (settings.startMinute != nil && settings.endMinute != nil &&
                   (0..<1440).contains(settings.startMinute!) && (0..<1440).contains(settings.endMinute!) &&
                   settings.startMinute != settings.endMinute)
            else { throw failure("Choose a supported interval and two different daily times.") }
        }
        for slot in 0..<(7 * 1440) {
            let minute = slot % 1440, weekday = slot / 1440 + 1
            guard value.collections.filter({ $0.playback?.contains(minute, weekday: weekday) == true }).count <= 1
            else { throw failure("Collection schedules cannot overlap on the same day. Adjust the other collection first.") }
        }
        guard Set(value.collections.map(\.id)).count == value.collections.count,
              Set(value.collections.map { $0.name.lowercased() }).count == value.collections.count,
              value.collections.allSatisfy({ !$0.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && $0.name.utf8.count <= 120 && $0.id.utf8.count <= 128 && Set($0.sceneIDs).count == $0.sceneIDs.count && $0.sceneIDs.allSatisfy { $0.utf8.count <= 128 } })
        else { throw failure("Use unique collection names (1–120 bytes) and unique item identifiers.") }
    }

    /// Internal transactional hook used by reconciliation and the durable backend.
    func commitCatalog(_ proposed: Catalog) throws { try save(proposed) }

    private func save(_ proposed: Catalog) throws {
        var next = proposed
        next.version = Self.catalogVersion
        try validateCatalog(next)
        let data = try JSONEncoder().encode(next)
        try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        try data.write(to: file, options: .atomic)
        catalog = next
    }

    private static func validMetadata(_ value: [String: String]?, maxPairs: Int) -> Bool {
        guard let value else { return true }
        return value.count <= maxPairs && value.allSatisfy {
            !$0.key.isEmpty && $0.key.utf8.count <= 128 && $0.value.utf8.count <= 2048
        }
    }
    private static func validObservation(_ value: ReconciliationObservation?) -> Bool {
        guard let value else { return true }
        guard value.byteLength.map({ $0 >= 0 }) ?? true,
              value.digestAlgorithm.map({ !$0.isEmpty && $0.utf8.count <= 32 }) ?? true,
              value.digest.map({ !$0.isEmpty && $0.utf8.count <= 256 }) ?? true,
              value.packageRevision.map({ !$0.isEmpty && $0.utf8.count <= 512 }) ?? true else { return false }
        return (value.digestAlgorithm == nil) == (value.digest == nil)
    }
    private static func validDimension(_ value: Int?) -> Bool { value.map { (1...131_072).contains($0) } ?? true }
    private static func validRate(_ value: Double?) -> Bool { value.map { $0.isFinite && $0 > 0 && $0 <= 1000 } ?? true }
    private static func validDuration(_ value: Double?) -> Bool { value.map { $0.isFinite && $0 >= 0 && $0 <= 604_800 } ?? true }
    private static func bounded(_ value: String, bytes: Int) -> String {
        var result = value
        while result.utf8.count > bytes && !result.isEmpty { result.removeLast() }
        return result
    }
    static func libraryFailure(_ text: String) -> NSError {
        NSError(domain: "IdlesseLibrary", code: 1, userInfo: [NSLocalizedDescriptionKey: text])
    }
    private func failure(_ text: String) -> NSError { Self.libraryFailure(text) }
}

/// Session-only rotation. A shuffle bag exhausts every member before repeating.
struct SceneRotationQueue {
    private var remaining: [String] = []
    private var members: [String] = []
    private var last: String?
    mutating func next(_ ids: [String], shuffle: Bool) -> String? {
        if ids != members { members = ids; remaining = [] }
        guard !ids.isEmpty else { return nil }
        if remaining.isEmpty {
            remaining = shuffle ? ids.shuffled() : ids
            if shuffle, remaining.count > 1, remaining.first == last {
                remaining.swapAt(0, 1)
            }
        }
        let result = remaining.removeFirst()
        last = result
        return result
    }
}
