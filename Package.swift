// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "LifeBoard",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "LifeBoardCore", targets: ["LifeBoardCore"]),
        .executable(name: "LifeBoard", targets: ["LifeBoardApp"]),
        .executable(name: "LifeBoardWidget", targets: ["LifeBoardWidget"]),
        // Keep the on-disk product name distinct from "LifeBoard". The default
        // macOS file system is case-insensitive, so a product named "lifeboard"
        // can overwrite the GUI executable during SwiftPM builds.
        .executable(name: "LifeBoardHelper", targets: ["LifeBoardCLI"]),
        .executable(name: "LifeBoardSelfTest", targets: ["LifeBoardSelfTest"])
    ],
    targets: [
        .target(name: "LifeBoardCore"),
        .executableTarget(name: "LifeBoardApp", dependencies: ["LifeBoardCore"], resources: [.process("Resources")]),
        .executableTarget(
            name: "LifeBoardWidget",
            dependencies: ["LifeBoardCore"],
            swiftSettings: [.unsafeFlags(["-application-extension"])],
            // WidgetKit extensions must enter through NSExtensionMain. A plain
            // SwiftPM executable's @main entry crashes during macOS discovery.
            linkerSettings: [.unsafeFlags(["-Xlinker", "-application_extension", "-Xlinker", "-e", "-Xlinker", "_NSExtensionMain"])]
        ),
        .executableTarget(name: "LifeBoardCLI", dependencies: ["LifeBoardCore"]),
        .executableTarget(name: "LifeBoardSelfTest", dependencies: ["LifeBoardCore"])
    ]
)
