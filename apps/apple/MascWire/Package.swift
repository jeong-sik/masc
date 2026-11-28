// swift-tools-version: 6.0
// MascWire: the Keeper chat wire types, generated from
// lib/keeper_chat_wire/keeper_chat_wire.atd by tools/atd-native-gen.
// Everything under Generated/ is generator output.
import PackageDescription

let package = Package(
    name: "MascWire",
    platforms: [.macOS(.v15), .iOS(.v18)],
    products: [.library(name: "MascWire", targets: ["MascWire"])],
    targets: [
        .target(name: "MascWire", path: "Generated"),
        .testTarget(name: "MascWireTests", dependencies: ["MascWire"], path: "Tests"),
    ]
)
