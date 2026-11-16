// swift-tools-version:5.9
import PackageDescription

// WikiCore is the Swift counterpart of reader/core: it reads the same .zim file and the same
// .zim.idx title index as the Android app. The iOS app itself is built from App/ by the Xcode
// project that project.yml describes. wikicheck is a command-line tool for comparing WikiCore
// with the Kotlin implementation on the Mac; it builds with the command-line tools alone
// (`swift build`), which the app does not: SwiftUI's macros need Xcode.
let package = Package(
    name: "WikiCore",
    platforms: [.iOS(.v16), .macOS(.v13)],
    products: [
        .library(name: "WikiCore", targets: ["WikiCore"]),
    ],
    dependencies: [
        // ZIM clusters are zstd-compressed and Apple's Compression framework has no zstd.
        .package(url: "https://github.com/facebook/zstd", exact: "1.5.7"),
    ],
    targets: [
        .target(name: "WikiCore", dependencies: [.product(name: "libzstd", package: "zstd")]),
        .executableTarget(name: "wikicheck", dependencies: ["WikiCore"]),
    ]
)
