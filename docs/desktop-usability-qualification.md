# Desktop usability qualification

## September 14 Show Desktop menu motion (supersedes the correction below)

During Show Desktop the Dock's display replaces its native `Menubar` window
(layer 24) with an opaque frozen snapshot of the wallpaper plus menu titles.
Captured alpha is 255 there and 0 on the built-in display; moving the pointer
does not change which display does it. A window at layer 24 stays under the
snapshot, and ordering below another process's status items is refused.

The menu strip is therefore hidden except while Show Desktop is active, detected
by Dock's layer-18 window covering the display (polled every 0.25 s, so hot
corners and gestures count too), and only on the Dock's display. While active it
sits at status level over the whole bar and draws two ScreenCaptureKit captures
above the live frames: the native `Menubar` window's titles, captured per menu
bar owner while the bar is still transparent, and the status-item windows,
recaptured about once a second. Without Screen Recording, or before the current
owner's titles have been captured, the strip stays hidden and the native
snapshot shows. A hidden strip cannot reach fullscreen spaces. State changes are
traced to `~/Library/Logs/Idlesse-menu-strip.log`.

Screen Recording grants follow the code signature, so `build.sh` signs the app
with the local "SmolRunner Local Release Signing" identity when present; ad-hoc
rebuilds silently lose the grant. Keep one app copy (`build/Idlesse.app`,
linked from `~/Applications`): stale copies share the bundle identifier and
leave duplicate privacy entries. The user confirmed whole-bar motion on
September 14.

## September 15 transition timing

Both Show Desktop transitions were measured with a live ScreenCaptureKit stream
on the native `Menubar` window, which reports the frozen snapshot appearing and
going away without per-sample capture cost, while a window-list sampler recorded
the Dock's reveal window. Three runs each, external display, macOS 26:

| Edge | Event | Measured |
| --- | --- | --- |
| Reveal | Dock reveal window → bar frozen | 29, 30, 65 ms |
| Restore | Dock reveal window gone → bar transparent again | 1012, 1028, 1089 ms |

The Dock therefore drops its reveal window about a second before the native bar
comes back, so hiding the strip when that window disappears leaves the frozen
snapshot on screen for the rest of the restore animation. The strip now stays up
for a fixed second after the reveal window goes and then fades out over 0.25 s,
which straddles the handover in both directions. Verified by window-list alpha
samples: the strip was still fully opaque at the moment the bar thawed and gone
about 250 ms later.

Reveal detection moved off the main thread. One window list costs 1.8 ms at the
median, 3.7 ms at p90 and occasionally 50 ms, so it runs on a background queue
every 50 ms and only state changes hop to the main thread (measured at 0 ms hop,
3 ms to present, 56 ms to the first copied frame). A `SCScreenshotManager`
capture costs about 100 ms, so captures are now confined to periods when nothing
is animating: never within 0.5 s of a reveal, never during the restore hold or
fade. An earlier attempt that probed the bar's transparency every 80 ms during
the restore produced visible jitter and was replaced by the fixed hold.

## September 14 correction

The status-level Show Desktop workaround below has been removed: promoting a
wallpaper strip over the native menu can leak into fullscreen content. Menu
strips now stay immediately above their desktop surface, strictly below normal
application windows. Show Desktop no longer captures menu labels, delays reveal
for capture, or uses private SkyLight ordering. The native menu background may
remain still; the earlier motion results do not qualify this revised behavior.
Fullscreen visual verification is still required.

## Historical Show Desktop menu background — September 13

The external display's native Menubar window becomes opaque during Show Desktop,
covering the still-moving GPU strip. The built-in display's native menu remains
transparent. Independent-window captures confirmed that difference; reverting the
monitor-sync build and toggling the system menu-background setting did not fix it.
The system setting was restored to off.

The macOS 26 fallback captures one transparent native menu-label image in memory
before Idlesse invokes Show Desktop. It temporarily puts the existing live strip
above the opaque backdrop, below native status items, and overlays those labels.
The window stays click-through. No extra decoder, video recording, or saved
capture is used. A weak-linked SkyLight sublevel call affects only Idlesse's own
window; unavailable APIs, missing permission, opaque captures, and capture timeouts
leave the ordinary strip in place. Screen Recording permission is required.

A state-aware ScreenCaptureKit probe checks Dock reveal geometry before and after
each small-region sample, without activating apps or saving screenshots:

```sh
swiftc -parse-as-library scripts/probe-menu-bar-motion.swift -o build/probe-menu-bar-motion
build/probe-menu-bar-motion
```

With Hina and Show Desktop active throughout, the diagnostic launch measured
external visible/beneath-native-menu deltas of 22.186/22.952 and built-in deltas
of 12.226/11.156. Both moved. Native menu labels and status icons were visually
present; File menu interaction worked. Restoring windows reset strip ordering.
Video preparation and targeted-assignment smoke tests passed.

Screen Recording was subsequently enabled for the canonical app through System
Settings. Normal-launch capture logged one prepared label layer, but the subsequent
probe found Show Desktop absent; that run is inconclusive, not another motion pass.
Further repeated visual verification was stopped at the user's request.

Scope: Idlesse-triggered reveal, external displays, macOS 26, transparent native
menu background, and Animate menu bar enabled. Native hotkeys/hot corners outside
Idlesse are not independently primed. Ad-hoc-signed rebuilds may need permission
reauthorization. Small-region motion is not proof of full-display scanout sync.

Qualification checkpoint: app source `cb0ef06`, September 12, 2026.

| Requirement | Evidence | Status |
| --- | --- | --- |
| Coverage-rest reveal delay | DesktopRevealPolicy tests cover slow dispatch, duplicate request, success grace, failure; live Show/Restore exercised | Implemented; visible animation latency not measured |
| Menu strip enabled for ordinary videos | Shared renderer predicate; plain-image/video on/off smoke checks; existing Hina produced paired presentation timestamps | Verified |
| Menu strip synchronization | Display 3: 1,330 pairs, 1.06 ms mean absolute skew, 12.50 ms max, 2 missed copies. Display 1: 1,166 pairs, 3.96 ms mean, 16.67 ms max, 246 misses | Measured sample; not atomic |
| Thumbnail memory and refresh | Bounded ImageIO thumbnail path, coalescing and stale-result rejection smoke checks | Verified |
| Library navigation and preview isolation | Home/Library smoke, real Ichika video poster, manual chooser/cancel and current Hina state | Verified |
| Current playback controls | Live popover Pause/Resume and toolbar labels; playback restored | Verified |
| Native chooser ownership | Opens sheet, Cancel returns to Library; no legacy saver detour | Verified |
| Wallpaper/display preservation | Existing Hina remains active; no display configuration operations | Verified for this work |

Final checkpoint commands passed:

- `./test.sh`
- `build/Idlesse.app/Contents/MacOS/Idlesse --smoke-home`
- `--smoke-library` with an existing 4K60 Ichika video; includes composed-video poster
- `git diff --check`

The development app was rebuilt and relaunched after app edits. The wallpaper
surface screenshot showed the current Hina scene rendered correctly. The UI
capture returns individual windows; it did not capture the combined menu material
and wallpaper in one image. That is not proof of visual menu-bar parity.

## Remaining qualification

- Measure user-visible desktop-reveal animation latency, distinct from the logged
  Mission Control dispatch completion.
- Inspect combined menu material and desktop for crop/color continuity. Paired
  timestamps cannot detect spatial mismatch or macOS blur/refraction.
- Determine whether the larger missed-copy count on display 1 warrants a scheduling
  change. Do not increase decode work or force the desktop to wait for the strip
  solely to make the counters look better.

The measured skew is an observed limitation of the current two-window presentation
path, not evidence that macOS cannot support a different implementation. No claim
of zero hitch, atomic presentation, global FPS improvement, or energy improvement
is made. The long-running qualification goal remains open.

## Drawable-buffer trial

The menu strip now permits three drawables (previously two); the ready/request
queue remains bounded to one each. Only the narrow strip gains a buffer.
With the existing wallpaper, before/after samples were:

| Buffer count | Display | Paired frames | Missed copies | Mean absolute skew | Maximum |
| --- | --- | ---: | ---: | ---: | ---: |
| 2 | 3 | 9658 | 195 | 0.62 ms | 25.00 ms |
| 2 | 1 | 9066 | 2279 | 4.96 ms | 33.34 ms |
| 3 | 3 | 3725 | 57 | 0.80 ms | 25.00 ms |
| 3 | 1 | 3873 | 16 | 0.85 ms | 50.00 ms |

These are sequential, unequal-duration live samples, not controlled benchmarks.
The display-1 missed-copy ratio and mean improved markedly, but worst-case skew
increased; do not infer atomic synchronization or universally lower latency.
The main renderer does not wait for the strip and no additional decoder is used.

### Prepared scene handoff

Replacement selection now waits for render readiness before retiring the active scene or starting a crossfade. Candidates are ordered transparent, muted, and noninteractive during preparation. Metal readiness requires a completed full-frame GPU command; Standard video uses AVPlayerLayer readiness, and layered scenes require every visible child. A ten-second preparation deadline fails the selection rather than forcing an unready frame onto the desktop. Cancellation closes candidate windows and their shared decoder; candidate decoder errors are retained until selection can report failure, without stopping the existing wallpaper.

This preparation temporarily retains both scenes and their resources. The deadline bounds loading time, not peak memory. Further qualification should cover rapid replacement, decoder failure, and suspension during preparation.

The rebuilt app restored Hina, then completed Library selection Hina → Tiger → Hina. The final Library state reports Hina on desktop with playback running. This verifies ordinary real-media handoff completion; it is not a frame-by-frame latency measurement.

`--smoke-selection-transactions` now exercises the real selection controller with a deliberately delayed source that ignores cancellation. It verifies active surface identity is retained during loading, the newer request wins even when the old provider returns late, and a failed load retains the selected scene and surface while reporting exactly one error. It runs without presenting test wallpaper windows or persisting selection. This does not yet qualify decoder failure after render preparation begins.

Preparation also checks the surface generation, so display rebuilds invalidate pending candidates. Lifecycle cancellation restores the active package watcher and exits without an error dialog. Home shows a compact Loading indicator beside the current display status while preparation runs.

### Launch and replacement goal audit — September 13

| Requirement | Evidence |
| --- | --- |
| Keep backdrop visible during startup | Metal surface and menu strip stay transparent until successful GPU completion; rebuilt app restores Hina and reports it playing. |
| Keep active scene until replacement is ready | Adoption and crossfade begin only after all candidate surfaces report ready. Live Library Hina → Tiger → Hina completed. |
| Real first-frame readiness | `--smoke-video-preparation` with the existing Hina video passed shared-decoder preparation while candidate opacity remained zero and mouse interaction disabled. |
| Failed decoder stays invisible and cleans up | The same test gives the decoder a missing video; it reports failure without readiness or visibility, then closes candidate and hub. |
| Failed load preserves working scene | `--smoke-selection-transactions` checks selected URL and surface identity survive failure and only the current error is reported. |
| Rapid selection / late cancellation | The transaction test deliberately lets a cancelled source return after the latest selection; it cannot replace the active scene or report a stale error. |
| Loading feedback | Home keeps the active title and transport available, adding Loading… to destination status only while loading. Home smoke passes. |
| Preserve user state | Final native UI shows Hina On Desktop, Pause available, All Displays, and Wallpaper Sound unchecked. No display settings or source media were changed. |
| PR separation | #101 remains the product PR based on #113; the independent native provider experiment remains draft #114. |

Commands run on the final build: `--smoke-video-preparation <existing Hina.mp4>`, `--smoke-selection-transactions`, and `--smoke-home`. All passed. The earlier full suite also passed after main reconciliation.

Limits: readiness uses GPU command completion for Metal and AVPlayerLayer readiness for Standard; this is not a physical scanout synchronization guarantee. Keeping old and new decoders alive briefly increases transient memory. A preparation timeout preserves the previous selection rather than forcing an unready surface visible. Per-monitor hotplug and sleep behavior are guarded by generation/suspension checks but were not physically disturbed during this qualification. No universal load-time, energy, or frame-rate improvement is claimed.
