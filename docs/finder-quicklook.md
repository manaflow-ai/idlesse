# Finder and Quick Look

Idlesse registers `.idlesse` as the package UTI `com.teamleaderleo.idlesse.scene` and embeds two sandboxed application extensions in `Idlesse.app`:

- `IdlesseThumbnail.appex` implements `QLThumbnailProvider` for Finder thumbnails.
- `IdlesseQuickLook.appex` implements a data-based `QLPreviewProvider` for Space-bar Quick Look.

Both extensions produce a still representative frame. Motion stays in the app/runtime where lifecycle and resource controls are explicit.

## Representative frame

The extensions resolve the package with `LocalSceneSource`, then render it with the production `MetalSceneRenderer` offline path. Scene parsing, feature/version checks, effects, masks, compositing, text, shapes, shaders, particles, video sampling, bindings and authored playback therefore share the same semantics as Idlesse itself.

The frame time is `metadata.previewTime` when authored. Packages without that field use 2 seconds, matching the Library poster convention. Preview signals contain scene time only: pointer and audio inputs stay at zero and the extension runtime never starts the app's input-capture subsystem.

Quick Look receives a 1280×720 PNG. Finder thumbnails preserve the same 16:9 poster aspect inside Finder's requested maximum size and display scale, capped at 1600×900.

## Bounds and failure behavior

Extension output is capped at 1,440,000 pixels (5,760,000 bytes of BGRA readback before PNG encoding). The existing scene/runtime limits remain active underneath that cap:

- each scene JSON file is limited to 64 KiB;
- packages accept at most 16 top-level nodes and group depth is capped at two;
- image decoding keeps the production pixel/edge limits;
- Metal intermediate targets retain the production 128 MiB cap;
- cancellation is checked before and during package resolution and offline rendering.

Malformed packages, unsupported format revisions/features, missing assets, escaped asset paths and render failures return an extension error. Finder/Quick Look can then display the system generic package representation. Source media stays untouched.

## Permissions

Both extensions use the App Sandbox with read-only user-selected file access. Their entitlement file contains no network client grant and no audio/input grant. The extension compile slice excludes wallpaper controllers, Studio/UI controllers, preferences, Photos, system-audio capture and FinderSync.

## Metadata and document handling

The data-based Quick Look reply exposes the scene title through `QLPreviewReply.title`. Author, description, tags and license remain package metadata; the public data-based reply API used here has no corresponding metadata fields.

The app's document registration owns `.idlesse` for Open With and Dock/Finder drops. External `.idlesse` file opens are classified separately from raw wallpaper media and deep links: scene packages open in Studio as their original document, while other supported media retain the existing direct wallpaper-selection behavior. Opening a scene document therefore does not silently replace the desktop wallpaper.

## Build and verification

`./build.sh` produces the extensions at:

```text
build/Idlesse.app/Contents/PlugIns/IdlesseThumbnail.appex
build/Idlesse.app/Contents/PlugIns/IdlesseQuickLook.appex
```

The development build uses the repository's existing direct `swiftc` + ad-hoc signing path. Public notarization is outside local development.

`bash test.sh` covers malformed packages, the 64 KiB JSON limit, the 16-node bound, authored/default preview time, external-open classification, thumbnail fitting and output caps. GitHub Actions also compiles both real extension binaries, validates their plists, verifies signatures and checks their sandbox/read-only entitlements.

For physical Finder validation on a Mac after building and launching `Idlesse.app`, inspect extension registration with `pluginkit`, then select an `.idlesse` package in Finder for its icon thumbnail and press Space for Quick Look. Also double-click/Open With an `.idlesse` package and confirm it opens in Studio without changing the active wallpaper. A release gate should verify this Finder-hosted path on a physical Mac because CI compilation cannot prove Finder's extension discovery/cache behavior.
