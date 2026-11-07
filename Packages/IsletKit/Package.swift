// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "IsletKit",
    platforms: [.iOS(.v18), .macOS(.v15), .watchOS(.v11)],
    products: [
        .library(name: "IsletKit", targets: ["IsletKit"]),
    ],
    targets: [
        .target(name: "IsletKit"),
        .testTarget(name: "IsletKitTests", dependencies: ["IsletKit"]),
    ]
)
