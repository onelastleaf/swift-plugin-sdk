// swift-tools-version: 6.2
import PackageDescription

let package = Package(
  name: "swift-plugin-sdk",
  platforms: [.macOS(.v15)],
  products: [
    .library(name: "OnelastleafPluginSDK", targets: ["OnelastleafPluginSDK"]),
    .executable(name: "PluginSDKConformance", targets: ["PluginSDKConformance"]),
  ],
  dependencies: [
    .package(url: "https://github.com/grpc/grpc-swift-2.git", exact: "2.4.2"),
    .package(url: "https://github.com/grpc/grpc-swift-nio-transport.git", from: "2.9.0"),
    .package(url: "https://github.com/grpc/grpc-swift-protobuf.git", exact: "2.4.0"),
    .package(url: "https://github.com/apple/swift-crypto.git", from: "3.12.0"),
    .package(url: "https://github.com/apple/swift-protobuf.git", from: "1.38.0"),
  ],
  targets: [
    .target(
      name: "OnelastleafPluginProtocol",
      dependencies: [
        .product(name: "GRPCCore", package: "grpc-swift-2"),
        .product(name: "GRPCProtobuf", package: "grpc-swift-protobuf"),
        .product(name: "SwiftProtobuf", package: "swift-protobuf"),
      ],
      plugins: [
        .plugin(name: "GRPCProtobufGenerator", package: "grpc-swift-protobuf")
      ]
    ),
    .target(
      name: "OnelastleafPluginSDK",
      dependencies: [
        "OnelastleafPluginProtocol",
        .product(name: "GRPCCore", package: "grpc-swift-2"),
        .product(name: "GRPCNIOTransportHTTP2Posix", package: "grpc-swift-nio-transport"),
        .product(name: "Crypto", package: "swift-crypto"),
        .product(name: "SwiftProtobuf", package: "swift-protobuf"),
      ]
    ),
    .executableTarget(
      name: "PluginSDKConformance",
      dependencies: ["OnelastleafPluginSDK"]
    ),
    .testTarget(name: "OnelastleafPluginSDKTests", dependencies: ["OnelastleafPluginSDK"]),
  ]
)
