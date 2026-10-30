// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "Bugfixes",
    platforms: [.iOS(.v15), .macCatalyst(.v15), .macOS(.v12)],
    products: [.library(name: "Bugfixes", targets: ["Bugfixes"])],
    targets: [
        .target(name: "Bugfixes"),
        .testTarget(name: "BugfixesTests", dependencies: ["Bugfixes"]),
    ]
)
