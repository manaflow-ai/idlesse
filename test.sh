#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")"
mkdir -p build/tests
CLEAN=0; OPT_FLAG="-Onone"
for arg in "$@"; do case "$arg" in --clean) CLEAN=1 ;; --release) OPT_FLAG="-O" ;; esac; done
[[ "${CONFIG:-}" == "release" ]] && OPT_FLAG="-O"
needs_build(){ local target="$1"; shift; [[ "$CLEAN" -eq 1 || ! -f "$target" ]] && return 0; for src in "$@"; do [[ "$src" -nt "$target" ]] && return 0; done; return 1; }
pids=(); SCENE_GEOMETRY_SRCS=(Sources/Runtime/SceneGeometrySupport.swift)
DECODER_SRCS=(Sources/Shared/ScalingMode.swift Sources/Shared/Preferences.swift Sources/Shared/DisplayImageDecoder.swift Sources/Shared/ImageCanvasView.swift Tests/main.swift)
needs_build build/tests/decoder "${DECODER_SRCS[@]}" && { xcrun swiftc "$OPT_FLAG" "${DECODER_SRCS[@]}" -framework AppKit -framework ScreenSaver -framework ImageIO -o build/tests/decoder & pids+=($!); }
SCENES_SRCS=("${SCENE_GEOMETRY_SRCS[@]}" Sources/Runtime/Scene.swift Sources/Runtime/SceneClock.swift Tests/SceneTests.swift)
needs_build build/tests/scenes "${SCENES_SRCS[@]}" && { xcrun swiftc "$OPT_FLAG" "${SCENES_SRCS[@]}" -framework CoreGraphics -o build/tests/scenes & pids+=($!); }
RECOVERY_SRCS=("${SCENE_GEOMETRY_SRCS[@]}" Sources/Runtime/Scene.swift Sources/Harness/SceneDocument.swift Tests/RecoveryTests.swift)
needs_build build/tests/recovery "${RECOVERY_SRCS[@]}" && { xcrun swiftc "$OPT_FLAG" "${RECOVERY_SRCS[@]}" -framework CoreGraphics -framework AppKit -framework AVFoundation -o build/tests/recovery & pids+=($!); }
AUDIO_SRCS=("${SCENE_GEOMETRY_SRCS[@]}" Sources/Runtime/Scene.swift Sources/Runtime/SceneClock.swift Sources/Runtime/AudioBandAnalyzer.swift Tests/AudioTests.swift)
needs_build build/tests/audio "${AUDIO_SRCS[@]}" && { xcrun swiftc "$OPT_FLAG" "${AUDIO_SRCS[@]}" -framework CoreGraphics -o build/tests/audio & pids+=($!); }
COMFORT_SRCS=(Sources/Wallpaper/DesktopComfortController.swift Tests/ComfortTests.swift)
needs_build build/tests/comfort "${COMFORT_SRCS[@]}" && { xcrun swiftc "$OPT_FLAG" "${COMFORT_SRCS[@]}" -framework AppKit -o build/tests/comfort & pids+=($!); }
LIBRARY_SRCS=(Sources/Harness/SceneLibraryStore.swift Sources/Harness/SceneLibraryReconciliation.swift Sources/Harness/SceneLibrarySafety.swift Tests/LibraryTests.swift)
needs_build build/tests/library "${LIBRARY_SRCS[@]}" && { xcrun swiftc "$OPT_FLAG" "${LIBRARY_SRCS[@]}" -o build/tests/library & pids+=($!); }
LIBRARY_RECONCILE_SRCS=(Sources/Harness/SceneLibraryStore.swift Sources/Harness/SceneLibraryReconciliation.swift Sources/Harness/SceneLibrarySafety.swift Tests/LibraryReconciliationTests.swift)
needs_build build/tests/library-reconcile "${LIBRARY_RECONCILE_SRCS[@]}" && { xcrun swiftc "$OPT_FLAG" "${LIBRARY_RECONCILE_SRCS[@]}" -o build/tests/library-reconcile & pids+=($!); }
LIBRARY_GRID_SRCS=(Sources/Harness/LibraryGridView.swift Tests/LibraryGridVirtualizationTests.swift)
needs_build build/tests/library-grid "${LIBRARY_GRID_SRCS[@]}" && { xcrun swiftc "$OPT_FLAG" -D LIBRARY_GRID_VIRTUALIZATION_TESTS "${LIBRARY_GRID_SRCS[@]}" -framework AppKit -o build/tests/library-grid & pids+=($!); }
AMBIENT_SET_SRCS=(Sources/Wallpaper/AmbientSet.swift Sources/Wallpaper/AmbientSetStore.swift Sources/Wallpaper/AmbientLegacyAdapter.swift Tests/AmbientSetTests.swift)
needs_build build/tests/ambient-sets "${AMBIENT_SET_SRCS[@]}" && { xcrun swiftc "$OPT_FLAG" "${AMBIENT_SET_SRCS[@]}" -o build/tests/ambient-sets & pids+=($!); }
VARIANT_SRCS=("${SCENE_GEOMETRY_SRCS[@]}" Sources/Runtime/Scene.swift Tests/VariantTests.swift)
needs_build build/tests/variants "${VARIANT_SRCS[@]}" && { xcrun swiftc "$OPT_FLAG" "${VARIANT_SRCS[@]}" -framework CoreGraphics -o build/tests/variants & pids+=($!); }
QUICKLOOK_SRCS=("${SCENE_GEOMETRY_SRCS[@]}" Sources/Runtime/Scene.swift Sources/Runtime/ScenePreviewPolicy.swift Sources/Harness/DocumentOpenRouter.swift Tests/QuickLookTests.swift)
needs_build build/tests/quick-look "${QUICKLOOK_SRCS[@]}" && { xcrun swiftc "$OPT_FLAG" "${QUICKLOOK_SRCS[@]}" -framework CoreGraphics -o build/tests/quick-look & pids+=($!); }
STUDIO_MOTION_SRCS=("${SCENE_GEOMETRY_SRCS[@]}" Sources/Runtime/Scene.swift Sources/Harness/StudioMotionAuthoring.swift Tests/StudioMotionTests.swift)
needs_build build/tests/studio-motion "${STUDIO_MOTION_SRCS[@]}" && { xcrun swiftc "$OPT_FLAG" "${STUDIO_MOTION_SRCS[@]}" -framework CoreGraphics -o build/tests/studio-motion & pids+=($!); }
AUTOMATION_SRCS=(Sources/Automation/AutomationCommand.swift Tests/AutomationCommandTests.swift)
needs_build build/tests/automation "${AUTOMATION_SRCS[@]}" && { xcrun swiftc "$OPT_FLAG" "${AUTOMATION_SRCS[@]}" -o build/tests/automation & pids+=($!); }
WALLPAPER_POLICY_SRCS=(Sources/Wallpaper/MirrorPresentationTiming.swift Sources/Wallpaper/CoverageRestPolicy.swift Sources/Wallpaper/CoverageMonitor.swift Sources/Wallpaper/DisplayAssignmentStore.swift Tests/WallpaperPolicyTests.swift)
needs_build build/tests/wallpaper-policy "${WALLPAPER_POLICY_SRCS[@]}" && { xcrun swiftc "$OPT_FLAG" "${WALLPAPER_POLICY_SRCS[@]}" -framework AppKit -o build/tests/wallpaper-policy & pids+=($!); }
DISPLAY_TOPOLOGY_SRCS=(Sources/Wallpaper/DisplayTopology.swift Sources/Wallpaper/DisplayAssignmentStore.swift Tests/DisplayTopologyTests.swift)
needs_build build/tests/display-topology "${DISPLAY_TOPOLOGY_SRCS[@]}" && { xcrun swiftc "$OPT_FLAG" "${DISPLAY_TOPOLOGY_SRCS[@]}" -framework AppKit -o build/tests/display-topology & pids+=($!); }
for pid in ${pids[@]+"${pids[@]}"}; do wait "$pid"; done
build/tests/decoder
build/tests/scenes
build/tests/recovery
build/tests/audio
build/tests/comfort
build/tests/library
build/tests/library-reconcile
build/tests/library-grid
build/tests/ambient-sets
build/tests/variants
build/tests/quick-look
build/tests/studio-motion
build/tests/automation
build/tests/wallpaper-policy
build/tests/display-topology
python3 Tests/HomeShellContractTests.py
