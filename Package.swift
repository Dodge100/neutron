// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "NeutronDownloadCore",
    platforms: [
        .macOS(.v13)
    ],
    products: [
        .library(name: "DownloadManagerCore", targets: ["DownloadManagerCore"])
    ],
    targets: [
        .target(
            name: "DownloadManagerCore",
            path: "neutron/DownloadCore",
            sources: [
                "DownloadManagerFeatures.swift"
            ]
        ),
        .testTarget(
            name: "DownloadManagerCoreTests",
            dependencies: ["DownloadManagerCore"],
            path: "Tests/DownloadManagerCoreTests"
        )
    ]
)
