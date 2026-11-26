// swift-tools-version:5.10
import Foundation
import PackageDescription

// libmpv comes from Homebrew: /opt/homebrew on Apple Silicon, /usr/local on Intel.
let brew = ProcessInfo.processInfo.environment["HOMEBREW_PREFIX"]
    ?? (FileManager.default.fileExists(atPath: "/opt/homebrew/include/mpv") ? "/opt/homebrew" : "/usr/local")

let package = Package(
    name: "Cornelia",
    platforms: [.macOS(.v14)],
    targets: [
        .systemLibrary(name: "CMpv", path: "Sources/CMpv"),
        .executableTarget(
            name: "Cornelia",
            dependencies: ["CMpv"],
            path: "Sources/Cornelia",
            swiftSettings: [.unsafeFlags(["-Xcc", "-I\(brew)/include", "-Xcc", "-DGL_SILENCE_DEPRECATION"])],
            linkerSettings: [
                .unsafeFlags(["-L\(brew)/lib", "-Xlinker", "-rpath", "-Xlinker", "\(brew)/lib"]),
                .linkedFramework("OpenGL"),
            ]
        ),
    ]
)
