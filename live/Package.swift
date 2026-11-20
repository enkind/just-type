// swift-tools-version:5.9
import PackageDescription
let package = Package(
    name: "JustType",
    platforms: [.macOS(.v13)],
    targets: [.executableTarget(name: "JustType", path: "Sources/JustType",
                                linkerSettings: [.linkedFramework("Accelerate"), .linkedFramework("Carbon"), .linkedFramework("AppKit")])]
)
