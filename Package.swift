// swift-tools-version: 6.1
import PackageDescription

let package = Package(
    name: "Hostig",
    platforms: [
        .macOS(.v14)
    ],
    products: [
        .executable(name: "Hostig", targets: ["HostigApp"])
    ],
    targets: [
        .executableTarget(
            name: "HostigApp",
            path: "Sources/HostigApp"
        )
    ]
)
