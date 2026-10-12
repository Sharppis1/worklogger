// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "Worklogger",
    platforms: [.macOS(.v13)],
    products: [
        .executable(name: "WorkloggerApp", targets: ["WorkloggerApp"]),
        .library(name: "WorkloggerCore", targets: ["WorkloggerCore"])
    ],
    targets: [
        .systemLibrary(
            name: "CSQLite",
            pkgConfig: "sqlite3",
            providers: [.brew(["sqlite3"])]
        ),
        .target(
            name: "WorkloggerCore",
            dependencies: ["CSQLite"],
            resources: [.copy("Resources/default-classification.json")]
        ),
        .executableTarget(
            name: "WorkloggerApp",
            dependencies: ["WorkloggerCore"]
        ),
        .testTarget(
            name: "WorkloggerCoreTests",
            dependencies: ["WorkloggerCore"]
        )
    ]
)
