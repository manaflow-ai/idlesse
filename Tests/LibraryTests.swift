import Foundation

@main struct LibraryTests {
    struct LegacyEntry: Codable {
        var id: String
        var title: String
        var bookmark: Data
    }
    struct LegacyCatalog: Codable {
        var entries: [LegacyEntry]
        var favorites: Set<String>
        var recent: [String: Date]
        var collections: [SceneLibraryStore.Collection]?
    }

    static func expectFailure(_ message: String, _ action: () throws -> Void) {
        do { try action(); fatalError(message) } catch {}
    }

    static func bookmark(_ url: URL) throws -> Data {
        let accessed = url.startAccessingSecurityScopedResource()
        defer { if accessed { url.stopAccessingSecurityScopedResource() } }
        return try url.bookmarkData(options: [.withSecurityScope], includingResourceValuesForKeys: nil, relativeTo: nil)
    }

    static func assertContents(_ url: URL, equal expected: Data, _ message: String = "") throws {
        let actual = try Data(contentsOf: url)
        precondition(actual == expected, message)
    }

    static func main() throws {
        var ordered = SceneRotationQueue()
        precondition((0..<7).compactMap { _ in ordered.next(["a", "b", "c"], shuffle: false) } == ["a", "b", "c", "a", "b", "c", "a"])
        var shuffled = SceneRotationQueue()
        var previous: String?
        for _ in 0..<100 {
            let cycle = (0..<3).compactMap { _ in shuffled.next(["a", "b", "c"], shuffle: true) }
            precondition(Set(cycle) == Set(["a", "b", "c"]))
            precondition(cycle.first != previous)
            previous = cycle.last
        }
        precondition(shuffled.next([], shuffle: true) == nil)
        precondition(shuffled.next(["only"], shuffle: true) == "only")
        precondition(shuffled.next(["only"], shuffle: true) == "only")

        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("idlesse-library-\(UUID())")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }

        // Existing individual-bookmark behavior and collection/schedule behavior stay intact.
        let media = folder.appendingPathComponent("Example.png")
        try Data([1, 2, 3]).write(to: media)
        let file = folder.appendingPathComponent("Index/library.json")
        let store = try SceneLibraryStore(file: file)
        let entry = try store.add(media)
        let duplicate = try store.add(media)
        precondition(duplicate == entry)
        precondition(entry.bookmark != nil && entry.sourceID == nil)
        try store.favorite(entry.id)
        let entriesBeforeUse = store.catalog.entries
        try store.used(entry.id)
        precondition(store.catalog.entries == entriesBeforeUse, "Using a wallpaper must preserve All Wallpapers")
        let afterUse = try SceneLibraryStore(file: file)
        precondition(afterUse.catalog.entries == entriesBeforeUse, "Using must preserve persisted library entries")
        let collection = try store.createCollection(name: " Chill ")
        try store.toggleMembership(sceneID: entry.id, collectionID: collection.id)
        try store.toggleMembership(sceneID: "builtin.Undertow", collectionID: collection.id)
        expectFailure("Duplicate collection accepted") { _ = try store.createCollection(name: "chill") }
        expectFailure("Empty collection accepted") { _ = try store.createCollection(name: "  ") }
        try store.setPlayback(collection.id, .init(minutes: 15, shuffle: true, startMinute: 1320, endMinute: 420))
        let other = try store.createCollection(name: "Day")
        expectFailure("Overlapping schedule accepted") { try store.setPlayback(other.id, .init(startMinute: 400, endMinute: 600)) }
        try store.setPlayback(other.id, .init(startMinute: 420, endMinute: 1320))
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "America/Toronto")!
        let base = calendar.date(from: DateComponents(year: 2026, month: 9, day: 9))!
        for minute in 0..<1440 {
            let date = calendar.date(byAdding: .minute, value: minute, to: base)!
            let expected = minute < 420 || minute >= 1320 ? collection.id : other.id
            precondition(store.scheduledCollection(at: date, calendar: calendar)?.id == expected)
        }
        expectFailure("Empty range accepted") { try store.setPlayback(other.id, .init(startMinute: 0, endMinute: 0)) }
        expectFailure("Invalid interval accepted") { try store.setPlayback(other.id, .init(minutes: 1)) }
        try store.removeCollection(other.id)
        try store.setPlayback(collection.id, .init(startMinute: 1320, endMinute: 420, weekdays: [6]))
        let friday = calendar.date(from: DateComponents(year: 2026, month: 9, day: 11, hour: 23))!
        let saturday = calendar.date(from: DateComponents(year: 2026, month: 9, day: 12, hour: 6))!
        precondition(store.scheduledCollection(at: friday, calendar: calendar)?.id == collection.id)
        precondition(store.scheduledCollection(at: saturday, calendar: calendar)?.id == collection.id)
        precondition(store.scheduledCollection(at: saturday.addingTimeInterval(3600), calendar: calendar) == nil)
        precondition(store.scheduledCollection(at: friday.addingTimeInterval(86400), calendar: calendar) == nil)
        let weekend = try store.createCollection(name: "Weekend")
        expectFailure("Overnight spill overlap accepted") { try store.setPlayback(weekend.id, .init(startMinute: 360, endMinute: 480, weekdays: [7])) }
        try store.setPlayback(weekend.id, .init(startMinute: 1320, endMinute: 420, weekdays: [7]))
        expectFailure("Empty days accepted") { try store.setPlayback(weekend.id, .init(weekdays: [])) }
        expectFailure("Invalid day accepted") { try store.setPlayback(weekend.id, .init(weekdays: [8])) }
        try store.moveCollection(weekend.id, by: -1)
        let collectionOrder = try SceneLibraryStore(file: file)
        precondition(collectionOrder.catalog.collections.first?.id == weekend.id)
        try store.moveCollection(weekend.id, by: 1)
        try store.removeCollection(weekend.id)
        try store.moveScene("builtin.Undertow", in: collection.id, by: -1)
        let reorderedStore = try SceneLibraryStore(file: file)
        precondition(reorderedStore.catalog.collections.first?.sceneIDs == ["builtin.Undertow", entry.id])
        try store.moveScene("builtin.Undertow", in: collection.id, by: -1)
        try store.moveScene("builtin.Undertow", in: collection.id, by: 1)
        try store.setPlayback(collection.id, .init(minutes: 15, shuffle: true, startMinute: 1320, endMinute: 420))
        let reopened = try SceneLibraryStore(file: file)
        precondition(reopened.catalog.collections.first?.playback?.minutes == 15)
        precondition(reopened.catalog.collections.first?.playback?.shuffle == true)
        precondition(reopened.catalog.collections.first?.sceneIDs == [entry.id, "builtin.Undertow"])
        try reopened.renameCollection(collection.id, name: "Evening")
        precondition(reopened.catalog.entries == [entry])
        precondition(reopened.catalog.favorites.contains(entry.id) && reopened.catalog.recent[entry.id] != nil)
        do {
            let access = try reopened.access(entry)
            precondition(access.url.standardizedFileURL == media.standardizedFileURL)
            access.close()
        }
        try reopened.remove(entry.id)
        precondition(reopened.catalog.collections.first?.sceneIDs == ["builtin.Undertow"])
        try reopened.removeCollection(collection.id)
        precondition(reopened.catalog.collections.isEmpty)
        precondition(reopened.catalog.entries.isEmpty && reopened.catalog.favorites.isEmpty && reopened.catalog.recent.isEmpty)
        try assertContents(media, equal: Data([1, 2, 3]), "Removing a reference must preserve the original")

        // Decode the exact pre-Library-2 entry model without rewriting it on open.
        let legacyFile = folder.appendingPathComponent("Legacy/index.json")
        let legacyMedia = folder.appendingPathComponent("Legacy Wallpaper.png")
        try Data([4, 5, 6]).write(to: legacyMedia)
        let legacyID = "legacy-entry"
        let legacyCollection = SceneLibraryStore.Collection(id: "legacy-collection", name: "Legacy Collection",
            sceneIDs: [legacyID, "builtin.Undertow"], playback: .init(minutes: 30, shuffle: false))
        let legacyPayload = LegacyCatalog(entries: [LegacyEntry(id: legacyID, title: "Legacy Wallpaper", bookmark: try bookmark(legacyMedia))],
            favorites: [legacyID], recent: [legacyID: Date(timeIntervalSinceReferenceDate: 1234)], collections: [legacyCollection])
        try FileManager.default.createDirectory(at: legacyFile.deletingLastPathComponent(), withIntermediateDirectories: true)
        let legacyBytes = try JSONEncoder().encode(legacyPayload)
        try legacyBytes.write(to: legacyFile)
        let legacyStore = try SceneLibraryStore(file: legacyFile)
        precondition(legacyStore.catalog.version == 1)
        precondition(legacyStore.catalog.sources.isEmpty)
        precondition(legacyStore.catalog.entries.count == 1 && legacyStore.catalog.entries[0].bookmark != nil)
        precondition(legacyStore.catalog.favorites == [legacyID])
        precondition(legacyStore.catalog.collections.first?.sceneIDs == [legacyID, "builtin.Undertow"])
        try assertContents(legacyFile, equal: legacyBytes, "Opening a legacy index must be side-effect free")
        do {
            let access = try legacyStore.access(legacyStore.catalog.entries[0])
            precondition(access.url.standardizedFileURL == legacyMedia.standardizedFileURL)
            access.close()
        }

        // First successful mutation performs the bounded v2 encode while preserving user state.
        try legacyStore.used(legacyID)
        let migratedObject = try JSONSerialization.jsonObject(with: Data(contentsOf: legacyFile)) as! [String: Any]
        precondition(migratedObject["version"] as? Int == SceneLibraryStore.catalogVersion)
        precondition(legacyStore.catalog.favorites == [legacyID])
        precondition(legacyStore.catalog.collections.first?.sceneIDs == [legacyID, "builtin.Undertow"])

        // Add one folder-backed catalog beside the old individual entry.
        let sourceA = folder.appendingPathComponent("Blue Archive A", isDirectory: true)
        try FileManager.default.createDirectory(at: sourceA.appendingPathComponent("wallpapers"), withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: sourceA.appendingPathComponent("posters"), withIntermediateDirectories: true)
        let sourceMediaA = sourceA.appendingPathComponent("wallpapers/Hina.mov")
        let sourcePosterA = sourceA.appendingPathComponent("posters/Hina.jpg")
        try Data([7, 8, 9]).write(to: sourceMediaA)
        try Data([10, 11]).write(to: sourcePosterA)
        let source = try legacyStore.addSource(sourceA, name: "Blue Archive", catalogMetadata: ["catalog": "test-v1"], entries: [
            .init(relativeMediaPath: "wallpapers/Hina.mov", title: "Hina (Dress)", catalogID: "blue-archive.hina.dress",
                  relativePosterPath: "posters/Hina.jpg", series: "Blue Archive", character: "Hina", variant: "Dress",
                  tags: ["night", "dress"], mediaType: "video", width: 3840, height: 2160, fps: 60, duration: 12,
                  provenance: ["origin": "catalog-test"])
        ])
        precondition(legacyStore.catalog.sources == [source])
        precondition(legacyStore.catalog.entries.count == 2)
        let sourceEntry = legacyStore.catalog.entries.first { $0.sourceID == source.id }!
        precondition(sourceEntry.bookmark == nil)
        precondition(sourceEntry.catalogID == "blue-archive.hina.dress")
        precondition(sourceEntry.relativeMediaPath == "wallpapers/Hina.mov")
        precondition(sourceEntry.relativePosterPath == "posters/Hina.jpg")
        precondition(sourceEntry.series == "Blue Archive" && sourceEntry.character == "Hina" && sourceEntry.variant == "Dress")
        precondition(sourceEntry.tags == ["night", "dress"] && sourceEntry.mediaType == "video")
        precondition(sourceEntry.width == 3840 && sourceEntry.height == 2160 && sourceEntry.fps == 60 && sourceEntry.duration == 12)
        precondition(sourceEntry.provenance == ["origin": "catalog-test"])
        precondition(legacyStore.catalog.entries.first { $0.id == legacyID }?.bookmark != nil, "Legacy individual bookmarks must remain individual")
        do {
            let access = try legacyStore.access(sourceEntry)
            precondition(access.sourceID == source.id)
            precondition(access.url.standardizedFileURL == sourceMediaA.standardizedFileURL)
            access.close()
            let poster = try legacyStore.accessPoster(sourceEntry)!
            precondition(poster.url.standardizedFileURL == sourcePosterA.standardizedFileURL)
            poster.close()
        }
        try legacyStore.favorite(sourceEntry.id)
        try legacyStore.used(sourceEntry.id)
        try legacyStore.toggleMembership(sceneID: sourceEntry.id, collectionID: legacyCollection.id)
        let mixed = try SceneLibraryStore(file: legacyFile)
        precondition(mixed.catalog.entries.map(\.id) == [legacyID, sourceEntry.id])
        precondition(mixed.catalog.favorites == Set([legacyID, sourceEntry.id]))
        precondition(mixed.catalog.collections.first?.sceneIDs == [legacyID, "builtin.Undertow", sourceEntry.id])

        // Lexical traversal is rejected before any catalog mutation.
        let beforeTraversal = try Data(contentsOf: legacyFile)
        for bad in ["../outside.png", "/tmp/outside.png", "wallpapers/../../outside.png", "wallpapers//Hina.mov", "./Hina.mov", ""] {
            expectFailure("Unsafe relative path accepted: \(bad)") {
                _ = try mixed.addSourceEntries(source.id, [.init(relativeMediaPath: bad)])
            }
            try assertContents(legacyFile, equal: beforeTraversal)
        }
        let sourceRelative = try SceneLibraryStore.relativePath(from: sourceA, to: sourceMediaA)
        precondition(sourceRelative == "wallpapers/Hina.mov")
        expectFailure("Outside child accepted as a relative Source path") {
            _ = try SceneLibraryStore.relativePath(from: sourceA, to: legacyMedia)
        }

        // Existing symlinks that leave the selected root are rejected again at resolution time.
        let outside = folder.appendingPathComponent("Outside", isDirectory: true)
        try FileManager.default.createDirectory(at: outside, withIntermediateDirectories: true)
        try Data([99]).write(to: outside.appendingPathComponent("secret.png"))
        try FileManager.default.createSymbolicLink(at: sourceA.appendingPathComponent("escape"), withDestinationURL: outside)
        let symlinkAdded = try mixed.addSourceEntries(source.id, [.init(relativeMediaPath: "escape/secret.png")])
        precondition(symlinkAdded.count == 1)
        expectFailure("Symlink escape resolved outside Source") { _ = try mixed.access(symlinkAdded[0]) }
        try mixed.remove(symlinkAdded[0].id)

        // A missing root keeps the full index and is repaired by changing one Source bookmark.
        try FileManager.default.removeItem(at: sourceA)
        let beforeMissing = try Data(contentsOf: legacyFile)
        expectFailure("Missing Source root resolved") { _ = try mixed.access(sourceEntry) }
        try assertContents(legacyFile, equal: beforeMissing)
        precondition(mixed.catalog.favorites.contains(sourceEntry.id))
        precondition(mixed.catalog.collections.first?.sceneIDs.contains(sourceEntry.id) == true)

        let sourceB = folder.appendingPathComponent("Blue Archive B", isDirectory: true)
        try FileManager.default.createDirectory(at: sourceB.appendingPathComponent("wallpapers"), withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: sourceB.appendingPathComponent("posters"), withIntermediateDirectories: true)
        let sourceMediaB = sourceB.appendingPathComponent("wallpapers/Hina.mov")
        let sourcePosterB = sourceB.appendingPathComponent("posters/Hina.jpg")
        try Data([7, 8, 9]).write(to: sourceMediaB)
        try Data([10, 11]).write(to: sourcePosterB)
        try mixed.relinkSource(source.id, to: sourceB)
        precondition(mixed.catalog.sources.first?.id == source.id)
        precondition(mixed.catalog.entries.first { $0.sourceID == source.id }?.id == sourceEntry.id)
        precondition(mixed.catalog.favorites == Set([legacyID, sourceEntry.id]))
        precondition(mixed.catalog.collections.first?.sceneIDs == [legacyID, "builtin.Undertow", sourceEntry.id])
        do {
            let repaired = try mixed.access(sourceEntry)
            precondition(repaired.url.standardizedFileURL == sourceMediaB.standardizedFileURL)
            repaired.close()
            let repairedPoster = try mixed.accessPoster(sourceEntry)!
            precondition(repairedPoster.url.standardizedFileURL == sourcePosterB.standardizedFileURL)
            repairedPoster.close()
        }

        // Re-adding the same root merges only new relative paths and retains existing IDs.
        try Data([12]).write(to: sourceB.appendingPathComponent("wallpapers/Arona.png"))
        let sameSource = try mixed.addSource(sourceB, entries: [
            .init(relativeMediaPath: "wallpapers/Hina.mov"),
            .init(relativeMediaPath: "wallpapers/Arona.png", catalogID: "blue-archive.arona", mediaType: "image")
        ])
        precondition(sameSource.id == source.id)
        precondition(mixed.catalog.sources.count == 1)
        precondition(mixed.catalog.entries.filter { $0.sourceID == source.id }.count == 2)
        precondition(mixed.catalog.entries.first { $0.catalogID == "blue-archive.hina.dress" }?.id == sourceEntry.id)

        // Source removal deletes Library references only and preserves unrelated state and source media.
        let sourceFileBytes = try Data(contentsOf: sourceMediaB)
        let sourceIDs = Set(mixed.catalog.entries.filter { $0.sourceID == source.id }.map(\.id))
        let pendingAccess = mixed.accessRequest(sourceEntry)
        try mixed.removeSource(source.id)
        precondition(mixed.catalog.sources.isEmpty)
        let capturedAccess = try pendingAccess.open()
        precondition(capturedAccess.url.standardizedFileURL == sourceMediaB.standardizedFileURL,
                     "Queued access must use its captured source reference rather than a mutated catalog")
        capturedAccess.close()
        precondition(mixed.catalog.entries.map(\.id) == [legacyID])
        precondition(mixed.catalog.favorites == [legacyID])
        precondition(mixed.catalog.recent[legacyID] != nil)
        precondition(mixed.catalog.recent.keys.allSatisfy { !sourceIDs.contains($0) })
        precondition(mixed.catalog.collections.first?.sceneIDs == [legacyID, "builtin.Undertow"])
        try assertContents(sourceMediaB, equal: sourceFileBytes, "Removing a Source must preserve source media")
        try assertContents(legacyMedia, equal: Data([4, 5, 6]))

        // Recent state remains bounded for large catalogs by retaining the newest 256 entries.
        for index in 0..<300 { try mixed.used("recent-\(index)") }
        precondition(mixed.catalog.recent.count == 256)
        precondition(mixed.catalog.recent["recent-299"] != nil)

        // Catalogs larger than the former product caps must load and persist.
        let tooManyIndividualsFile = folder.appendingPathComponent("Limits/individuals.json")
        try FileManager.default.createDirectory(at: tooManyIndividualsFile.deletingLastPathComponent(), withIntermediateDirectories: true)
        let oneBookmark = try bookmark(legacyMedia)
        let tooManyIndividuals = LegacyCatalog(entries: (0...4096).map {
            LegacyEntry(id: "legacy-\($0)", title: "Wallpaper \($0)", bookmark: oneBookmark)
        }, favorites: [], recent: [:], collections: [])
        let tooManyIndividualBytes = try JSONEncoder().encode(tooManyIndividuals)
        try tooManyIndividualBytes.write(to: tooManyIndividualsFile)
        let largeIndividuals = try SceneLibraryStore(file: tooManyIndividualsFile)
        precondition(largeIndividuals.catalog.entries.count == 4097)
        try assertContents(tooManyIndividualsFile, equal: tooManyIndividualBytes)

        let sourceLimitFile = folder.appendingPathComponent("Limits/source-entries.json")
        let sourceLimitStore = try SceneLibraryStore(file: sourceLimitFile)
        let sourceLimitRoot = folder.appendingPathComponent("Limit Source", isDirectory: true)
        try FileManager.default.createDirectory(at: sourceLimitRoot, withIntermediateDirectories: true)
        let sourceLimit = try sourceLimitStore.addSource(sourceLimitRoot)
        let tooManySourceEntries = (0...4096).map {
            SceneLibraryStore.SourceEntry(relativeMediaPath: "entry-\($0).png")
        }
        _ = try sourceLimitStore.addSourceEntries(sourceLimit.id, tooManySourceEntries)
        let reloadedSource = try SceneLibraryStore(file: sourceLimitFile)
        precondition(reloadedSource.catalog.entries.count == 4097)

        let sourceCountFile = folder.appendingPathComponent("Limits/sources.json")
        let rootBookmark = try bookmark(sourceLimitRoot)
        var sourceCountCatalog = SceneLibraryStore.Catalog()
        sourceCountCatalog.sources = (0...32).map {
            SceneLibraryStore.SourceRoot(id: "source-\($0)", name: "Source \($0)", bookmark: rootBookmark)
        }
        let sourceCountBytes = try JSONEncoder().encode(sourceCountCatalog)
        try sourceCountBytes.write(to: sourceCountFile)
        let largeSources = try SceneLibraryStore(file: sourceCountFile)
        precondition(largeSources.catalog.sources.count == 33)
        try assertContents(sourceCountFile, equal: sourceCountBytes)

        var expanded = reloadedSource.catalog
        expanded.favorites = Set(expanded.entries.prefix(300).map(\.id))
        expanded.collections = (0..<33).map {
            SceneLibraryStore.Collection(name: "Collection \($0)", sceneIDs: Array(expanded.entries.prefix(300).map(\.id)))
        }
        try reloadedSource.commitCatalog(expanded)
        let expandedReload = try SceneLibraryStore(file: sourceLimitFile)
        precondition(expandedReload.catalog.favorites.count == 300)
        precondition(expandedReload.catalog.collections.count == 33)
        precondition(expandedReload.catalog.collections.first?.sceneIDs.count == 300)

        // Semantically corrupt v2 paths fail closed and stay byte-for-byte preserved.
        let semanticFile = folder.appendingPathComponent("Limits/semantic.json")
        var semantic = SceneLibraryStore.Catalog()
        semantic.sources = [SceneLibraryStore.SourceRoot(id: "source", name: "Source", bookmark: rootBookmark)]
        semantic.entries = [SceneLibraryStore.Entry(id: "escape", title: "Escape", sourceID: "source", relativeMediaPath: "../outside.png")]
        let semanticBytes = try JSONEncoder().encode(semantic)
        try semanticBytes.write(to: semanticFile)
        expectFailure("Unsafe path in a saved index accepted") { _ = try SceneLibraryStore(file: semanticFile) }
        try assertContents(semanticFile, equal: semanticBytes)

        // Malformed, future-version, and oversized indexes are preserved byte for byte.
        let corruptFile = folder.appendingPathComponent("Corrupt/index.json")
        try FileManager.default.createDirectory(at: corruptFile.deletingLastPathComponent(), withIntermediateDirectories: true)
        let invalidBytes = Data("invalid".utf8)
        try invalidBytes.write(to: corruptFile)
        expectFailure("Corrupt index accepted") { _ = try SceneLibraryStore(file: corruptFile) }
        try assertContents(corruptFile, equal: invalidBytes, "A bad index must be preserved")

        var future = SceneLibraryStore.Catalog()
        future.version = SceneLibraryStore.catalogVersion + 1
        let futureBytes = try JSONEncoder().encode(future)
        try futureBytes.write(to: corruptFile)
        expectFailure("Future Library version accepted") { _ = try SceneLibraryStore(file: corruptFile) }
        try assertContents(corruptFile, equal: futureBytes)

        try Data(repeating: 0, count: 16_777_216 + 1).write(to: corruptFile)
        expectFailure("Malformed index accepted") { _ = try SceneLibraryStore(file: corruptFile) }
        let oversizedSize = (try FileManager.default.attributesOfItem(atPath: corruptFile.path)[.size] as? NSNumber)?.intValue
        precondition(oversizedSize == 16_777_216 + 1)

        print("Library checks passed: v1 migration, mixed bookmarks/sources, relink, path containment, metadata, state preservation, bounds, and corrupt-index preservation")
    }
}
