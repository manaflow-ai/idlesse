// swift-tools-version: 6.0
import PackageDescription

// SwiftPM wrapper for true incremental app builds. build.sh still owns
// .app/.saver bundling, code signing, and application extensions (which need
// -application-extension flags SwiftPM cannot express). This package only
// produces the app executable.
let package = Package(
    name: "Idlesse",
    platforms: [.macOS(.v14)],
    products: [
        .executable(name: "IdlesseApp", targets: ["IdlesseApp"]),
    ],
    targets: [
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
            ]
        ),
    ]
)
