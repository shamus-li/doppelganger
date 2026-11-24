// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "Doppelganger",
    platforms: [.macOS(.v15)],
    dependencies: [.package(url: "https://github.com/sparkle-project/Sparkle", exact: "2.10.1")],
    targets: [
        .executableTarget(
            name: "Doppelganger",
            dependencies: [.product(name: "Sparkle", package: "Sparkle")],
            // Sparkle.framework is copied into the app's Contents/Frameworks.
            linkerSettings: [.unsafeFlags(["-Xlinker", "-rpath", "-Xlinker", "@executable_path/../Frameworks"])]
        ),
        .testTarget(
            name: "DoppelgangerTests",
            dependencies: ["Doppelganger"],
            // The command line tools keep the Swift Testing macros in a subfolder the driver doesn't search.
            swiftSettings: [.unsafeFlags([
                "-load-plugin-library",
                "/Library/Developer/CommandLineTools/usr/lib/swift/host/plugins/testing/libTestingMacros.dylib",
            ])]
        ),
    ]
)
