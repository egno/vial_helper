// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "VialHelper",
    platforms: [.macOS(.v13)],
    targets: [
        .executableTarget(
            name: "VialHelper",
            path: "Sources/VialHelper",
            linkerSettings: [
                .linkedFramework("Carbon"),
                .linkedFramework("ServiceManagement"),
            ]
        ),
    ],
    swiftLanguageVersions: [.v5]
)
