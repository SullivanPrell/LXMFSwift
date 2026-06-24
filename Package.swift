// swift-tools-version:5.9
import PackageDescription
import Foundation

// ReticulumSwift dependency.
//
// Consumers get the published release from GitHub. For developing the whole
// stack from sibling checkouts (ReticulumSwift next to this repo), set
// RETICULUM_LOCAL_DEPS=1 to use the local path instead:
//
//   RETICULUM_LOCAL_DEPS=1 swift test
//
let useLocalDeps = ProcessInfo.processInfo.environment["RETICULUM_LOCAL_DEPS"] != nil
let reticulumDependency: Package.Dependency = useLocalDeps
    ? .package(path: "../ReticulumSwift")
    : .package(url: "https://github.com/SullivanPrell/ReticulumSwift.git", from: "1.0.0")

let package = Package(
    name: "LXMFSwift",
    platforms: [.macOS(.v13), .iOS(.v16)],
    products: [
        .library(name: "LXMF", targets: ["LXMF"]),
    ],
    dependencies: [
        reticulumDependency,
    ],
    targets: [
        .target(
            name: "LXMF",
            dependencies: [
                .product(name: "ReticulumSwift", package: "ReticulumSwift"),
            ]
        ),
        .testTarget(
            name: "LXMFTests",
            dependencies: [
                "LXMF",
                .product(name: "ReticulumSwift", package: "ReticulumSwift"),
            ]
        ),
    ]
)
