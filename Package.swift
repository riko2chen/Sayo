// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "Sayo",
    platforms: [.macOS(.v14)],
    products: [
        .executable(name: "SayoApp", targets: ["SayoApp"]),
        .executable(name: "sayo", targets: ["SayoCLI"]),
        .library(name: "SayoCore", targets: ["SayoCore"])
    ],
    dependencies: [
        .package(url: "https://github.com/sparkle-project/Sparkle", exact: "2.10.0")
    ],
    targets: [
        .target(name: "SayoCore"),
        .target(name: "SayoApplication", dependencies: ["SayoCore"]),
        .target(name: "SayoPlatform", dependencies: ["SayoCore"]),
        .target(name: "SayoLLM", dependencies: ["SayoCore"], resources: [.copy("Resources")]),
        .target(name: "SayoTerminal", dependencies: ["SayoCore"], resources: [.copy("Resources")]),
        .target(name: "SayoUI", dependencies: ["SayoCore", "SayoApplication"], resources: [.process("Resources")]),
        .target(name: "SayoAppRuntime", dependencies: ["SayoCore", "SayoApplication", "SayoPlatform", "SayoLLM", "SayoTerminal", "SayoUI"], path: "Sources/SayoApp"),
        .target(name: "SayoUpdates", dependencies: ["SayoCore", .product(name: "Sparkle", package: "Sparkle")]),
        .executableTarget(name: "SayoApp", dependencies: ["SayoAppRuntime", "SayoUpdates"], path: "Sources/SayoDirectApp",
                          linkerSettings: [.unsafeFlags(["-Xlinker", "-rpath", "-Xlinker", "@executable_path/../Frameworks"])]),
        .executableTarget(name: "SayoCLI", dependencies: ["SayoCore", "SayoTerminal"]),
        .testTarget(name: "SayoCoreTests", dependencies: ["SayoCore"]),
        .testTarget(name: "SayoUITests", dependencies: ["SayoCore", "SayoUI"]),
        .testTarget(name: "SayoUpdatesTests", dependencies: ["SayoCore", "SayoUpdates", .product(name: "Sparkle", package: "Sparkle")]),
        .testTarget(name: "SayoApplicationTests", dependencies: ["SayoCore", "SayoApplication"]),
        .testTarget(name: "SayoLLMTests", dependencies: ["SayoCore", "SayoLLM"]),
        .testTarget(name: "SayoPlatformTests", dependencies: ["SayoCore", "SayoPlatform"]),
        .testTarget(name: "SayoTerminalTests", dependencies: ["SayoCore", "SayoTerminal"])
    ],
    swiftLanguageModes: [.v5]
)
