// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "Hana",
    platforms: [.macOS("26.0")],
    products: [.executable(name: "Hana", targets: ["Hana"])],
    dependencies: [
        // Pinned exactly; see docs/technical-design.md "Collection Store foundation — issue #24".
        .package(url: "https://github.com/groue/GRDB.swift", exact: "7.11.1"),
        .package(url: "https://github.com/swiftlang/swift-markdown.git", exact: "0.9.0")
    ],
    targets: [
        .executableTarget(name: "Hana", dependencies: [
            .product(name: "GRDB", package: "GRDB.swift"),
            .product(name: "Markdown", package: "swift-markdown")
        ]),
        .testTarget(name: "HanaTests", dependencies: ["Hana", .product(name: "GRDB", package: "GRDB.swift")])
    ]
)
