// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "PodcastNotes",
    platforms: [.macOS(.v14)],
    products: [
        .executable(name: "PodcastNotes", targets: ["PodcastNotesApp"])
    ],
    targets: [
        .systemLibrary(name: "CSQLite"),
        .executableTarget(
            name: "PodcastNotesApp",
            dependencies: ["CSQLite"],
            resources: [.copy("Resources")]
        )
    ]
)
