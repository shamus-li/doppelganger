// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "Doppelganger",
    platforms: [.macOS(.v15)],
    targets: [
        .executableTarget(name: "Doppelganger"),
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
