// swift-tools-version: 5.9
import PackageDescription
import Foundation

let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().path
let package = Package(
    name: "LinkAll",
    platforms: [.macOS(.v14)],
    products: [.executable(name: "Yiliu", targets: ["Yiliu"]), .executable(name: "LinkAll", targets: ["LinkInputCompanion"])],
    targets: [
        .systemLibrary(name: "CSQLite", path: "src/CSQLite"),
        .target(name: "LinkAllShared", path: "src/Shared", exclude: ["UI"]),
        .target(name: "LinkAllUI", path: "src/Shared/UI", resources: [.copy("BrandAssets")]),
        .target(name: "LinkRecordCore", dependencies: ["CSQLite", "LinkAllShared"], path: "src/LinkRecord/Core"),
        .target(name: "LinkAgent", dependencies: ["LinkRecordCore"], path: "src/LinkAgent", exclude: ["README.md"]),
        .target(name: "LinkRecordUI", dependencies: ["LinkRecordCore", "LinkAllShared", "LinkAllUI"], path: "src/LinkRecord/UI"),
        .executableTarget(name: "LinkInputCompanion", dependencies: ["LinkAllShared", "LinkAllUI", "LinkRecordCore", "LinkRecordUI"], path: "src/LinkAll/App"),
        .target(name: "CRime", path: "src/LinkInput/Native", publicHeadersPath: "include",
                cSettings: [.headerSearchPath("../../../Vendor/include")],
                linkerSettings: [.unsafeFlags(["-L\(root)/Vendor/lib", "-lrime", "-Xlinker", "-rpath", "-Xlinker", "\(root)/Vendor/lib"])]),
        .target(name: "YiliuCore", dependencies: ["CRime"], path: "src/LinkInput/Core", resources: [.copy("Prompts")]),
        .executableTarget(name: "LinkAgentProbe", dependencies: ["LinkAgent", "YiliuCore", "LinkRecordCore"], path: "scripts/ReplyProbe"),
        .executableTarget(name: "YiliuProbe", dependencies: ["YiliuCore"], path: "scripts/Probe"),
        .executableTarget(name: "Yiliu", dependencies: ["YiliuCore", "LinkAgent", "LinkRecordCore", "LinkAllShared", "LinkAllUI"], path: "src/LinkInput/App",
                          resources: [.copy("Sounds")],
                          linkerSettings: [.linkedFramework("InputMethodKit"), .linkedFramework("Carbon")]),
        .testTarget(name: "YiliuTests", dependencies: ["YiliuCore", "LinkAgent", "LinkRecordUI", "LinkRecordCore", "LinkAllShared", "LinkAllUI"], path: "tests", exclude: ["expression-cases.json"])
    ]
)
