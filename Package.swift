// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "Shishi", platforms: [.macOS(.v13)],
    products: [.executable(name: "Shishi", targets: ["Shishi"])],
    targets: [
        .systemLibrary(name: "CSQLite", pkgConfig: "sqlite3"),
        .target(name: "ShishiCore", dependencies: ["CSQLite"]),
        .executableTarget(name: "Shishi", dependencies: ["ShishiCore"]),
        .testTarget(name: "ShishiCoreTests", dependencies: ["ShishiCore", "Shishi"])
    ]
)
