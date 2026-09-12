# Idlesse Library

Open Library from the preview window or Wallpaper menu (Command-L).

- Eight bundled scenes currently ship with the app: Desk Clock, After Hours, Undertow,
  Fireflies, Ripple, Audio Aurora, Aurora, and Breathing Aurora.
- Search by name; filter included/imported/favorites; sort by name or recently opened.
- Import… keeps the existing individual-file flow. Supported media stays in its current
  folder and each individually imported entry retains its own security-scoped bookmark.
  Existing indexes continue to resolve these entries exactly as before.
- Sources… → Add Source… adds a folder catalog. The user grants one folder bookmark,
  Idlesse performs one explicit bounded scan, and matching entries are saved as safe
  relative paths beneath that Source. The scan includes native `.idlesse`, JPEG, PNG,
  HEIC, MP4, and MOV media; it does not transcode files or rewrite the selected folder.
  A Source scan visits at most 20,000 filesystem items and the Library accepts at most
  4,096 source-backed entries total. Scanning ends when the add operation ends; there
  is no background rescan service or folder polling.
- Sources… → Relink <name>… replaces only that Source's folder bookmark. Stable Source
  and entry IDs, relative paths, favorites, recents, collections, schedules, and saved
  ordering remain intact. This is the recovery path after moving or renaming a root
  folder when its bookmark can no longer resolve it.
- Sources… → Remove <name>… removes the Source and its entries from the Library index.
  Favorites, recent records, and collection membership for those removed entries are
  cleaned from the index. Source media and poster files remain untouched.
- Remove from Library removes one entry and its favorite/recent metadata, never media.
  This works for individual imports and entries from a Source.
- Drop supported scene/media files onto the scene list to use the individual import
  pipeline. Unsupported dropped files are ignored.
- Adding individual scenes clears the search, opens Imported, and selects the first
  added scene. Video playability is probed asynchronously. Imports/conversions run
  sequentially in one cancellable batch and refresh the Library once on completion.
  Each file is attempted independently; failed imports are reported together while
  successful references remain available. Double-clicking empty list space does nothing.

## Library 2 index

The Library index remains native Foundation JSON under
`Application Support/Idlesse/Library/index.json`; there is no database dependency.
Library 2 writes catalog `version: 2` and keeps these top-level groups:

- `entries`: wallpaper references and metadata.
- `sources`: Source roots, each with a stable ID, user-facing name, one folder bookmark,
  and optional string catalog metadata.
- `favorites`, `recent`, and `collections`: the existing user state.

An entry uses one of two location forms. An individual import has a security-scoped
`bookmark`. A source-backed entry has `sourceID` plus `relativeMediaPath` and can also
carry `catalogID`, `relativePosterPath`, `series`, `character`, `variant`, `tags`,
`mediaType`, `width`, `height`, `fps`, `duration`, and string provenance fields.
Optional fields are omitted from JSON when empty so large catalogs stay compact.

Pre-Library-2 indexes have no `version` or `sources` key and contain entries with a
required bookmark. They decode as version 1 in memory without rewriting the file.
The first successful Library mutation writes version 2 atomically. Entry IDs, titles,
bookmarks, favorites, recent timestamps, collections, playback settings, and ordering
are carried forward. A failed decode, semantic validation failure, future catalog
version, oversized index, or failed save leaves the original index bytes in place and
reports the error instead of replacing the file.

Existing safety bounds remain in force: the JSON index is capped at 1 MiB; security
bookmarks at 16 KiB; individual imports at 128; Sources at 32; favorites and recent
state at 256; collections at 32 with 256 distinct scene references each. Source-backed
entries have a separate 4,096-entry bound. Recent state is kept to its newest 256
records as larger Source catalogs are used. The 1 MiB file cap can become the tighter
limit when entries contain rich metadata.

Relative media and poster paths must be non-empty relative paths with no absolute
prefix, empty component, `.` component, or `..` component. Resolution appends the
validated path to the authorized root and checks containment again after resolving
symlinks, so a symlink cannot redirect a catalog entry outside the granted folder.
A missing Source stays in the index and reports a Relink Source… recovery message.

Security-scoped access has an explicit owner. `SceneLibraryStore.Access` starts access
on the individual file bookmark or Source root bookmark and closes it when the access
object is released or explicitly closed. Thumbnail and selected-poster work retain an
access object for the duration of each read. A source-backed wallpaper or Studio handoff
keeps a Source access object alive beyond URL resolution so asynchronous consumers can
read descendants under the folder grant. The host can release those retained grants
when that wallpaper or Studio source is replaced.

Library storage versioning is independent of `.idlesse` scene revisions. This migration
does not change revision 21 scene format.

## Collections and playback

- Use Collections… → New Collection to create a named group. Select scenes in All
  Wallpapers, then use Collections… → Add to to assign them. Named collections appear
  in the filter menu. Within a collection, the same menu offers rename, delete, and
  removal of the selected scene. These operations never delete source media. Names must
  be unique, ignoring case.
- In a collection, choose Play Collection in Order or Shuffle Collection. Playback
  begins immediately and changes every 5, 15, 30 (default), or 60 minutes. Ordered
  playback follows membership insertion order, independent of the Library sort.
  Shuffle exhausts the collection before repeating and avoids an immediate repeat
  between cycles. Stop Collection Rotation, a manual wallpaper choice, or stopping
  the wallpaper ends rotation. Closing Library leaves rotation running.
  Each collection remembers its interval and ordered/shuffle preference.
  Manually started playback is session-only.
  Missing references are omitted; load failures keep the existing wallpaper and
  the next timer tick tries the next member. There is no catch-up burst after sleep.
- Playback & Schedule… provides native time pickers, interval and shuffle controls.
  Enable one local-time range per collection and choose its start days. Overnight ranges
  continue into the following morning; overlaps are checked across the entire week.
  Older daily schedules keep every day enabled. Overlapping ranges and equal start/end
  times are rejected. Schedules resume when the app launches and are evaluated every
  30 seconds (plus timer tolerance). Manual selection or Stop suppresses automatic
  playback through the current window; the next boundary resumes it. Outside scheduled
  ranges, the last wallpaper remains displayed without collection rotation. Bedtime
  remains separate. No app auto-launch or system wake is installed. A single-scene
  schedule can use a collection containing one scene.
- Collections retain saved order. Move Collection Up/Down arranges the collection menu;
  Move Scene Earlier/Later arranges playback. Collection views show playback order,
  regardless of the global sort setting.

## Posters and resource bounds

Select a scene for a still poster. Double-click or Set Wallpaper applies it. Open in
Studio edits imported packages; bundled scenes become untitled drafts. Make a Copy in
Studio starts a draft without overwriting its source. Source entries with an explicit
`relativePosterPath` use that poster for the small list thumbnail while selected-scene
preview still renders the actual composition.

Selected posters use the shared `ScenePreviewRuntime` that also backs Finder thumbnails
and Quick Look. The runtime resolves the authored preview time (default 2 seconds), keeps
pointer/audio inputs disabled, prepares video at that same time, renders through the
production Metal compositor, checks the same output/intermediate-memory bounds, and then
releases GPU resources. Authored video-following uses scene transport time; ordinary
looping video uses elapsed preview time. Studio supplies the moving composition. This is
a still-preview library rather than a grid of continuously playing wallpapers.

The memory cache holds at most four 1024×576 widescreen posters (about 9 MiB pixel data).
List and grid thumbnails share a separate cache capped at 64 images and 64 MiB. Packages
prefer a baked preview or decodable package asset. Assetless procedural packages then
use the shared runtime's immediate 320×180 still path at metadata `previewTime`, covering
shader, particle, gradient, text, and shape scenes without creating a second compositor
implementation. Thumbnail decoding and probe rendering stay on the utility thumbnail
queue, release renderer resources after each probe, and leave the existing placeholder
in place when generation fails. There is no disk thumbnail cache or original-media
duplication. Renderer working memory uses the existing scene budgets during generation.
Selecting a scene or reopening Library checks its revision before reusing a poster.
Packages use bounded JSON and file metadata revisions; raw media uses modification time
and size. Revision checks run off the main thread. Edits during generation discard the
result. Refresh Preview forces regeneration. Closing the Library cancels its request and
clears the image cache.

Cloud-backed individual media or Source descendants may need to download when explicitly
selected for preview.

Validation covers individual-bookmark round trips, version-1 decoding and lazy migration,
mixed individual and source-backed catalogs, moved/missing/relinked roots, traversal and
symlink escape rejection, metadata round trips, favorite/recent/collection preservation,
source removal without media deletion, retained legacy limits, source limits, corrupt and
future-version index preservation, generated Metal posters, bounded particle and shader
thumbnail probes, favorite filtering, empty searches, and bundled-scene routing to a
Studio draft. The offscreen UI capture exercises layout but cannot fully reproduce macOS
glass-control appearance; live UI validation remains separate from those tests.

## Wallpaper transitions and shared canvases

The wallpaper menu offers Instant or a 0.5/1/2-second crossfade. A replacement is prepared
first; the outgoing scene pauses during the fade and is released at completion. Rapid
selection, pause, bedtime, sleep, display changes, and Stop finish the transition
immediately. Reduce Motion uses instant switching. Instant remains the default.

Studio Playback offers Per Display and Span Desktop. V19 saves `canvas: desktopSpan`;
each wallpaper surface views its rectangle within the union of connected display frames
(in macOS logical points). Pointer bindings use that same union when pointer access is
enabled. Gaps and unequal monitor sizes are preserved. Studio and exports show the entire
scene in their own canvas aspect ratio. Video players still follow the existing approximate
clock behavior.
