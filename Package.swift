// swift-tools-version: 6.0
// The swift-tools-version declares the minimum version of Swift required to build this package.

import PackageDescription

let package = Package(
  name: "JSONRPCProxy",
  platforms: [
    .macOS(.v14)
  ],
  products: [
    .library(
      name: "JSONRPCProxy",
      targets: ["JSONRPCProxy"]
    ),
    .executable(
      name: "opencode-proxy",
      targets: ["OpenCodeProxy"]
    ),
  ],
  dependencies: [
    .package(url: "https://github.com/apple/swift-nio.git", from: "2.65.0"),
    .package(url: "https://github.com/swift-server/async-http-client.git", from: "1.21.0"),
    .package(url: "https://github.com/vapor/websocket-kit.git", from: "2.15.0"),
    .package(url: "https://github.com/apple/swift-log.git", from: "1.5.0"),
  ],
  targets: [
    .target(
      name: "JSONRPCProxy",
      dependencies: [
        .product(name: "NIO", package: "swift-nio"),
        .product(name: "NIOCore", package: "swift-nio"),
        .product(name: "NIOPosix", package: "swift-nio"),
        .product(name: "NIOHTTP1", package: "swift-nio"),
        .product(name: "AsyncHTTPClient", package: "async-http-client"),
        .product(name: "WebSocketKit", package: "websocket-kit"),
        .product(name: "Logging", package: "swift-log"),
      ]
    ),
    .executableTarget(
      name: "OpenCodeProxy",
      dependencies: ["JSONRPCProxy"]
    ),
    .testTarget(
      name: "JSONRPCProxyTests",
      dependencies: ["JSONRPCProxy"]
    ),
  ]
)
