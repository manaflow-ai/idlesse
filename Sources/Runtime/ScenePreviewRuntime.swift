import AppKit
import CoreGraphics
import Foundation

struct ScenePreviewFrame {
    let title: String
    let metadata: SceneMetadata?
    let previewTime: Double
    let image: CGImage

    var pixelSize: CGSize { CGSize(width: CGFloat(image.width), height: CGFloat(image.height)) }

    func pngData() throws -> Data {
        guard let data = NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:]) else {
            throw SceneError.invalid("Could not encode the scene preview.")
        }
        return data
    }
}

private final class ScenePreviewRenderErrorBox {
    var message: String?
}

private struct ScenePreviewRenderSession {
    let scene: SceneDescriptor
    let width: Int
    let height: Int
    let previewTime: Double
    let clock: SceneClock
    let renderer: MetalSceneRenderer
    let errors: ScenePreviewRenderErrorBox
}

/// One representative still renderer shared by Finder, Quick Look and Library.
/// Package resolution stays in LocalSceneSource and pixels come from the
/// production Metal compositor instead of a second preview implementation.
enum ScenePreviewRuntime {
    static func renderPackage(at url: URL, pixelSize: CGSize) async throws -> ScenePreviewFrame {
        guard url.isFileURL, url.pathExtension.lowercased() == "idlesse" else {
            throw SceneError.invalid("Quick Look previews require an .idlesse package.")
        }
        try Task.checkCancellation()
        let scene = try await LocalSceneSource().resolve(url)
        try Task.checkCancellation()
        return try await render(scene: scene, pixelSize: pixelSize)
    }

    /// Full offline still path. Video frames are prepared at the same authored
    /// poster time before the production compositor samples the scene.
    static func render(scene: SceneDescriptor, pixelSize: CGSize) async throws -> ScenePreviewFrame {
        let session = try makeSession(scene: scene, pixelSize: pixelSize)
        defer { session.renderer.releaseResources() }
        try Task.checkCancellation()
        try await session.renderer.prepareOfflineVideo(
            at: scene.timeline?.videosFollowScene == true ? session.clock.time : session.previewTime,
            size: CGSize(width: CGFloat(session.width), height: CGFloat(session.height))
        )
        try Task.checkCancellation()
        return try finish(session)
    }

    /// Immediate still path for callers that have already established that a
    /// package has no prepared video frame to sample (for example an assetless
    /// procedural Library thumbnail). It shares the same clock, input policy,
    /// compositor, readback checks and output bounds as the full path.
    static func renderImmediate(scene: SceneDescriptor, pixelSize: CGSize) throws -> ScenePreviewFrame {
        let session = try makeSession(scene: scene, pixelSize: pixelSize)
        defer { session.renderer.releaseResources() }
        return try finish(session)
    }

    private static func makeSession(scene: SceneDescriptor, pixelSize: CGSize) throws -> ScenePreviewRenderSession {
        let size = try ScenePreviewPolicy.validatedPixels(pixelSize)
        let previewTime = ScenePreviewPolicy.previewTime(for: scene)
        let clock = SceneClock(now: { 0 })
        try clock.configure(timeline: scene.timeline)
        try clock.seek(to: previewTime)
        // Package capabilities never grant host inputs. Representative posters
        // are deterministic time-only renders in every caller.
        clock.pointerEnabled = false
        clock.audioEnabled = false

        let errors = ScenePreviewRenderErrorBox()
        let renderer = try MetalSceneRenderer(
            playable: scene,
            bounds: NSRect(x: 0, y: 0, width: CGFloat(size.width), height: CGFloat(size.height)),
            scale: 1,
            clock: clock,
            onError: { errors.message = $0 }
        )
        return ScenePreviewRenderSession(scene: scene, width: size.width, height: size.height,
                                         previewTime: previewTime, clock: clock,
                                         renderer: renderer, errors: errors)
    }

    private static func finish(_ session: ScenePreviewRenderSession) throws -> ScenePreviewFrame {
        let bytes = try session.renderer.renderFrame(
            signals: SceneSignals(time: session.clock.time),
            width: session.width,
            height: session.height,
            sampleVideo: false
        )
        if let message = session.errors.message { throw SceneError.invalid(message) }
        guard session.renderer.intermediateTextureBytes <= SceneBudget.intermediateTextureBytes else {
            throw SceneError.invalid("Preview compositor exceeded its intermediate-texture budget.")
        }
        guard bytes.count == session.width * session.height * 4,
              bytes.count <= ScenePreviewPolicy.maxOutputBytes else {
            throw SceneError.invalid("Preview readback exceeded its bounded output budget.")
        }
        guard let provider = CGDataProvider(data: Data(bytes) as CFData),
              let colorSpace = CGColorSpace(name: CGColorSpace.sRGB),
              let image = CGImage(
                width: session.width,
                height: session.height,
                bitsPerComponent: 8,
                bitsPerPixel: 32,
                bytesPerRow: session.width * 4,
                space: colorSpace,
                bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedFirst.rawValue).union(.byteOrder32Little),
                provider: provider,
                decode: nil,
                shouldInterpolate: true,
                intent: .defaultIntent
              ) else {
            throw SceneError.invalid("Could not prepare the scene preview image.")
        }
        return ScenePreviewFrame(title: session.scene.title, metadata: session.scene.metadata,
                                 previewTime: session.previewTime, image: image)
    }
}
