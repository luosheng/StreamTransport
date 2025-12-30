# StreamBridge

A Swift package for bridging between different transport mechanisms. Stream data transparently between stdio, HTTP, WebSocket, and subprocess transports.

## Supported Transports

| Transport | Server Mode | Client Mode |
|-----------|-------------|-------------|
| **Stdio** | Reads from stdin | Writes to stdout |
| **HTTP** | `/in` (POST) receives data, `/out` (GET) streams data | HTTP client |
| **WebSocket** | WebSocket server | WebSocket client |
| **Process** | — | Subprocess stdin/stdout |

## Installation

Add to your `Package.swift`:

```swift
dependencies: [
    .package(url: "https://github.com/example/StreamBridge", from: "1.0.0")
]
```

## Usage

### Simple Stdio-to-Process Bridge

```swift
import StreamBridge

let inbound = StdioTransport(mode: .server)
let outbound = ProcessTransport(command: "opencode", arguments: ["acp"])
let bridge = Proxy(inbound: inbound, outbound: outbound)
try await bridge.run()
```

### HTTP to WebSocket Bridge

```swift
import StreamBridge

let bridge = Proxy(
    inboundType: .http(host: "0.0.0.0", port: 3000, path: "/"),
    outboundType: .webSocket(host: "localhost", port: 8080, path: "/ws")
)
try await bridge.run()
```

### WebSocket to Stdio Bridge

```swift
import StreamBridge

// Wrap a CLI tool with a WebSocket interface
let bridge = Proxy(
    inboundType: .webSocket(host: "0.0.0.0", port: 9000, path: "/"),
    outboundType: .stdio
)
try await bridge.run()
```

## Architecture

```
┌───────────────────────────────────────────────────────────────────┐
│                             Bridge                                │
│                                                                   │
│ ┌──────────────────────────┐         ┌──────────────────────────┐ │
│ │         Inbound          │         │         Outbound         │ │
│ │      (Server Mode)       │  ────▶ │      (Client Mode)       │ │
│ │                          │         │                          │ │
│ │  - StdioTransport        │         │  - StdioTransport        │ │
│ │  - HTTPTransport         │         │  - HTTPTransport         │ │
│ │  - WebSocketTransport    │         │  - WebSocketTransport    │ │
│ │                          │         │  - ProcessTransport      │ │
│ └──────────────────────────┘         └──────────────────────────┘ │
│                                                                   │
└───────────────────────────────────────────────────────────────────┘
```

## Transport Protocol

All transports implement the `Transport` protocol:

```swift
public protocol Transport: Actor {
    var mode: TransportMode { get }
    var isRunning: Bool { get }
    var messages: AsyncStream<Data> { get }
    
    func start() async throws
    func stop() async throws
    func send(_ data: Data) async throws
}
```

## Example: OpenCode Proxy

This package includes an example `opencode-proxy` that forwards stdin to `opencode acp`:

```bash
swift build
.build/debug/opencode-proxy
```

## Requirements

- macOS 14.0+
- Swift 6.0+

## Dependencies

- [SwiftNIO](https://github.com/apple/swift-nio)
- [AsyncHTTPClient](https://github.com/swift-server/async-http-client)
- [WebSocketKit](https://github.com/vapor/websocket-kit)
- [swift-log](https://github.com/apple/swift-log)

## License

MIT
