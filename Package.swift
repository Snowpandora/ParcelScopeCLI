// swift-tools-version: 6.0
import PackageDescription
let package = Package(
    name: "ParcelScopeCLI",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "ParcelScopeInspection", targets: ["ParcelScopeInspection"]),
        .executable(name: "parcelscope", targets: ["parcelscope"])
    ],
    targets: [
        .target(name: "ParcelScopeInspection"),
        .target(name: "ParcelScopeExecution", dependencies: ["ParcelScopeInspection"]),
        .executableTarget(name: "parcelscope", dependencies: ["ParcelScopeInspection", "ParcelScopeExecution"]),
        .testTarget(name: "ParcelScopeInspectionTests", dependencies: ["ParcelScopeInspection"]),
        .testTarget(name: "ParcelScopeExecutionTests", dependencies: ["ParcelScopeInspection", "ParcelScopeExecution"])
    ]
)
