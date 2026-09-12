import CoreGraphics
import Foundation

@main struct QuickLookTests {
    static func main() throws {
        let repository = URL(fileURLWithPath: FileManager.default.currentDirectoryPath, isDirectory: true)
        let fixtures = repository.appendingPathComponent("Tests/QuickLookFixtures", isDirectory: true)

        func expectRejected(_ name: String, containing expected: String? = nil) {
            let url = fixtures.appendingPathComponent(name, isDirectory: true)
            do {
                _ = try LocalSceneSource.read(url)
                preconditionFailure("Expected \(name) to be rejected")
            } catch {
                let message = error.localizedDescription
                precondition(!message.isEmpty)
                if let expected { precondition(message.contains(expected), "Unexpected rejection for \(name): \(message)") }
            }
        }

        expectRejected("Malformed.idlesse")
        expectRejected("TooManyNodes.idlesse", containing: "Use 1–16 layers in v1, or nodes in v2 and later.")

        let authoredURL = fixtures.appendingPathComponent("PreviewTime.idlesse", isDirectory: true)
        var authored = try LocalSceneSource.read(authoredURL)
        precondition(authored.title == "Preview Time Fixture")
        precondition(ScenePreviewPolicy.previewTime(for: authored) == 7.25)
        authored.metadata = nil
        precondition(ScenePreviewPolicy.previewTime(for: authored) == 2)

        precondition(IdlesseExternalOpenRoute.classify(authoredURL) == .sceneDocument)
        precondition(IdlesseExternalOpenRoute.classify(URL(fileURLWithPath: "/tmp/photo.jpg")) == .wallpaperMedia)
        precondition(IdlesseExternalOpenRoute.classify(URL(string: "idlesse://wallpapers")!) == .deepLink)

        let huge = ScenePreviewPolicy.thumbnailPixelSize(
            maximumSize: CGSize(width: 100_000, height: 100_000),
            scale: 4
        )!
        precondition(Int(huge.width) <= ScenePreviewPolicy.maxPixelWidth)
        precondition(Int(huge.height) <= ScenePreviewPolicy.maxPixelHeight)
        precondition(Int(huge.width * huge.height) <= ScenePreviewPolicy.maxOutputPixels)
        precondition(abs(huge.width / huge.height - 16.0 / 9.0) < 0.001)
        precondition(ScenePreviewPolicy.thumbnailPixelSize(maximumSize: CGSize(width: 8, height: 8), scale: 1) == nil)
        precondition(ScenePreviewPolicy.thumbnailPixelSize(maximumSize: CGSize(width: CGFloat.nan, height: 256), scale: 2) == nil)

        let full = try ScenePreviewPolicy.validatedPixels(ScenePreviewPolicy.previewPixelSize)
        precondition(full.width == 1280 && full.height == 720)
        do {
            _ = try ScenePreviewPolicy.validatedPixels(CGSize(width: 1601, height: 900))
            preconditionFailure("Oversized preview width should fail")
        } catch {}
        do {
            _ = try ScenePreviewPolicy.validatedPixels(CGSize(width: CGFloat.infinity, height: 900))
            preconditionFailure("Non-finite preview dimensions should fail")
        } catch {}
        do {
            _ = try ScenePreviewPolicy.validatedPixels(CGSize(width: CGFloat.greatestFiniteMagnitude, height: 900))
            preconditionFailure("Maximal finite preview dimensions should fail before integer conversion")
        } catch {}

        // Exercise the decoder's hard 64 KiB JSON read ceiling without storing a
        // large generated fixture in the repository.
        let oversized = FileManager.default.temporaryDirectory
            .appendingPathComponent("IdlesseQuickLook-\(UUID().uuidString).idlesse", isDirectory: true)
        try FileManager.default.createDirectory(at: oversized, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: oversized) }
        try Data(repeating: 0x20, count: 65_537).write(to: oversized.appendingPathComponent("manifest.json"))
        do {
            _ = try LocalSceneSource.read(oversized)
            preconditionFailure("Oversized manifest should fail")
        } catch {
            precondition(error.localizedDescription.contains("64 KB"))
        }

        print("quick-look-tests: ok")
    }
}
