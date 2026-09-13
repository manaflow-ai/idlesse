# Library visual review

Run after changing Library layout or interaction. Capture the app window itself with
CUA `getScreenshot()`; do not capture the entire desktop or change display configuration.
Keep captures under the ignored `build/qualification/` directory when exporting them.

1. Build and relaunch using `./build.sh run`.
2. Inspect the Library at its normal width and minimum supported width. Restore the
   original frame afterward. Check that search, import, playback, and view controls fit.
3. Capture Grid with Inspector closed and open. Check sidebar integration, selection
   contrast, thumbnail aspect ratios, and readable inspector actions.
4. Switch to List and back. Confirm the selected wallpaper and item order agree.
5. Search for an existing title, clear the search, and scroll. Browsing must not apply
   a wallpaper. Background refresh must not reset an unchanged list's scroll position.
6. Open Library actions and its New Collection sheet; cancel without creating test data.
7. Open the current wallpaper's playback popover. Confirm pause, sound, and display
   information remain reachable. Do not change display assignments merely to test layout.
8. Run `build/Idlesse.app/Contents/MacOS/Idlesse --smoke-home` and the relevant Library
   smoke checks when behavior changes. Screenshots complement these checks; they do
   not replace interaction verification.

Record actual observations and untested cases in the PR. Never claim multi-display
or light-mode verification from a single dark-mode screenshot.
