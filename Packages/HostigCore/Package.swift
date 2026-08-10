// swift-tools-version: 6.1
import PackageDescription

let package = Package(
    name: "HostigCore",
    platforms: [
        .macOS(.v14),
        .visionOS(.v2)
    ],
    products: [
        .library(name: "HostigModels", targets: ["HostigModels"]),
        .library(name: "HostigLocalServices", targets: ["HostigLocalServices"]),
        .library(name: "HostigLink", targets: ["HostigLink"]),
        .library(name: "HostigNetworking", targets: ["HostigNetworking"])
    ],
    targets: [
        .target(name: "HostigModels"),
        .target(
            name: "HostigLocalServices",
            dependencies: ["HostigModels", "HostigLink"]
        ),
        .target(
            name: "HostigLink",
            dependencies: ["HostigModels"]
        ),
        .target(
            name: "HostigNetworking",
            dependencies: ["HostigModels", "HostigLink"]
        ),
        .testTarget(
            name: "HostigLocalServicesTests",
            dependencies: ["HostigLocalServices"]
        )
    ]
)
