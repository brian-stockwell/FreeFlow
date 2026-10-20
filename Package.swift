// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "FreeFlow",
    platforms: [.macOS("26.0")],
    products: [
        .executable(name: "FreeFlow", targets: ["FreeFlow"])
    ],
    dependencies: [
        .package(url: "https://github.com/groue/GRDB.swift.git", from: "7.11.0")
    ],
    targets: [
        .executableTarget(
            name: "FreeFlow",
            dependencies: [
                .product(name: "GRDB", package: "GRDB.swift")
            ],
            path: "Sources/FreeFlow",
            resources: [.copy("../../Resources/sounds")],
            swiftSettings: [
                .swiftLanguageMode(.v5)
            ],
            linkerSettings: [
                .linkedFramework("AppKit"),
                .linkedFramework("SwiftUI"),
                .linkedFramework("Speech"),
                .linkedFramework("AVFoundation"),
                .linkedFramework("CoreAudio"),
                .linkedFramework("ApplicationServices"),
                .linkedFramework("Carbon"),
                .linkedFramework("ServiceManagement"),
                .linkedFramework("UserNotifications"),
            ]
        )
    ]
)
