// swift-tools-version: 6.0
// The swift-tools-version declares the minimum version of Swift required to build this package.

import PackageDescription

let package = Package(
  name: "StreamBridge",
  platforms: [
    .macOS(.v14),
    .iOS(.v17),
    .tvOS(.v17),
    .watchOS(.v10),
  ],
  products: [
    // Cross-platform core protocol
    .library(
      name: "StreamTransportCore",
      targets: ["StreamTransportCore"]
    ),
    // Cross-platform client implementations (iOS/macOS/tvOS/watchOS)
    .library(
      name: "StreamTransportClient",
      targets: ["StreamTransportClient"]
    ),
    // macOS-only server implementations
    .library(
      name: "StreamTransportServer",
      targets: ["StreamTransportServer"]
    ),
    // macOS-only proxy
    .library(
      name: "StreamProxy",
      targets: ["StreamProxy"]
    ),
    // macOS-only example executable
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
    // MARK: - Core Protocol (Cross-platform)
    .target(
      name: "StreamTransportCore",
      dependencies: [
        .product(name: "Logging", package: "swift-log")
      ]
    ),

    // MARK: - Client Implementations (Cross-platform)
    .target(
      name: "StreamTransportClient",
      dependencies: [
        "StreamTransportCore",
        .product(name: "Logging", package: "swift-log"),
      ]
    ),

    // MARK: - Server Implementations (macOS/Linux only)
    .target(
      name: "StreamTransportServer",
      dependencies: [
        "StreamTransportCore",
        .product(name: "NIO", package: "swift-nio"),
        .product(name: "NIOCore", package: "swift-nio"),
        .product(name: "NIOPosix", package: "swift-nio"),
        .product(name: "NIOHTTP1", package: "swift-nio"),
        .product(name: "AsyncHTTPClient", package: "async-http-client"),
        .product(name: "WebSocketKit", package: "websocket-kit"),
        .product(name: "Logging", package: "swift-log"),
      ]
    ),

    // MARK: - Proxy (macOS/Linux only)
    .target(
      name: "StreamProxy",
      dependencies: ["StreamTransportServer", "StreamTransportClient"]
    ),

    // MARK: - Example Executable (macOS only)
    .executableTarget(
      name: "OpenCodeProxy",
      dependencies: ["StreamProxy"]
    ),

    // MARK: - Tests
    .testTarget(
      name: "StreamBridgeTests",
      dependencies: ["StreamProxy"]
    ),
  ]
)
