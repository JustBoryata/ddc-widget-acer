// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "DDCWidget",
    platforms: [.macOS(.v13)],
    products: [
        .library(name: "DDCKit", targets: ["DDCKit"]),
        .executable(name: "acer-ddc", targets: ["acer-ddc"]),
        .executable(name: "DDCWidget", targets: ["DDCWidget"]),
    ],
    targets: [
        .target(
            name: "CIOAVService",
            linkerSettings: [.linkedFramework("IOKit"), .linkedFramework("CoreFoundation")]
        ),
        .target(name: "DDCKit", dependencies: ["CIOAVService"]),
        .executableTarget(name: "acer-ddc", dependencies: ["DDCKit"]),
        .executableTarget(name: "DDCWidget", dependencies: ["DDCKit"]),
    ]
)
