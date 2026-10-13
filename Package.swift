// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "Hana",
    platforms: [.macOS("26.0")],
    products: [.executable(name: "Hana", targets: ["Hana"])],
    targets: [
        .executableTarget(name: "Hana"),
        .testTarget(name: "HanaTests", dependencies: ["Hana"])
    ]
)
