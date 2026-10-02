// swift-tools-version: 6.0
import PackageDescription

// SwiftPM wrapper for true incremental app builds. build.sh still owns
// .app/.saver bundling, code signing, and application extensions (which need
// -application-extension flags SwiftPM cannot express). This package
// produces the app executable and the IdlesseRuntime library, which embedding
// hosts use to render .idlesse scenes. The app keeps compiling the runtime
// sources into its own module; RuntimeLibrary/ symlinks the same files into a
// separate library target, and only the embedding API there is `public`.
let package = Package(
    name: "Idlesse",
    platforms: [.macOS(.v14)],
    products: [
        .executable(name: "IdlesseApp", targets: ["IdlesseApp"]),
        .library(name: "IdlesseRuntime", targets: ["IdlesseRuntime"]),
    ],
    targets: [
        .target(
            name: "IdlesseRuntime",
            path: "RuntimeLibrary",
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
        .executableTarget(
            name: "IdlesseApp",
            path: "Sources",
            exclude: [
                "DesktopMenu",
                "QuickLook",
                "Harness/Info.plist",
                "Saver/Info.plist",
            ],
            swiftSettings: [.swiftLanguageMode(.v5)],
            linkerSettings: [
                .linkedFramework("AVFoundation"),
                .linkedFramework("ApplicationServices"),
                .linkedFramework("MetalKit"),
                .linkedFramework("Metal"),
                .linkedFramework("IOKit"),
                .linkedFramework("CoreLocation"),
                .linkedFramework("AppKit"),
                .linkedFramework("Photos"),
                .linkedFramework("ScreenSaver"),
                .linkedFramework("UniformTypeIdentifiers"),
                .linkedFramework("Carbon"),
                .linkedLibrary("sqlite3"),
            ]
        ),
    ]
)
