# JSONRPCProxy

一个 Swift Package，用于在不同的 JSON-RPC 传输方式之间进行代理转发。

## 支持的传输方式

| 传输方式 | Server 模式 | Client 模式 |
|---------|-------------|-------------|
| **Stdio** | 从 stdin 读取 | 写入 stdout |
| **HTTP** | HTTP 服务器监听端口 | HTTP Client 发送请求 |
| **WebSocket** | WebSocket 服务器 | WebSocket 客户端 |

## 安装

在 `Package.swift` 中添加依赖：

```swift
dependencies: [
    .package(url: "https://github.com/example/JSONRPCProxy", from: "1.0.0")
]
```

## 示例：OpenCode ACP Proxy

这个 package 包含一个示例可执行程序 `opencode-proxy`，它将 stdin 转发到 `opencode acp` 命令：

```bash
# 构建
swift build

# 运行
.build/debug/opencode-proxy
```

```swift
// Sources/OpenCodeProxy/main.swift
import JSONRPCProxy

let inbound = StdioTransport(mode: .server)
let outbound = ProcessTransport(command: "opencode", arguments: ["acp"])
let proxy = Proxy(inbound: inbound, outbound: outbound)
try await proxy.run()
```

```swift
import JSONRPCProxy

// 创建代理：从 stdin 接收消息，转发到 HTTP 服务器
let proxy = Proxy(
    inboundType: .stdio,
    outboundType: .http(host: "localhost", port: 8080, path: "/rpc")
)

try await proxy.run()
```

### 使用 Transport 实例

```swift
import JSONRPCProxy

// 创建自定义配置的 Transport
let inbound = StdioTransport(mode: .server)
let outbound = HTTPTransport(
    mode: .client,
    config: HTTPTransportConfiguration(
        host: "api.example.com",
        port: 443,
        path: "/jsonrpc"
    )
)

let proxy = Proxy(inbound: inbound, outbound: outbound)
try await proxy.start()

// 稍后停止
try await proxy.stop()
```

### HTTP 到 WebSocket 代理

```swift
import JSONRPCProxy

// HTTP 服务器接收请求，转发到 WebSocket 后端
let proxy = Proxy(
    inboundType: .http(host: "0.0.0.0", port: 3000, path: "/"),
    outboundType: .webSocket(host: "localhost", port: 8080, path: "/ws")
)

try await proxy.run()
```

### WebSocket 到 Stdio 代理

```swift
import JSONRPCProxy

// WebSocket 服务器接收消息，转发到 stdio（适用于包装命令行 LSP 服务器）
let proxy = Proxy(
    inboundType: .webSocket(host: "0.0.0.0", port: 9000, path: "/"),
    outboundType: .stdio
)

try await proxy.run()
```

## 架构

```
┌─────────────────────────────────────────────────────────┐
│                       Proxy                              │
│                                                          │
│  ┌──────────────────┐       ┌──────────────────┐        │
│  │     Inbound      │       │    Outbound      │        │
│  │   (Server Mode)  │ ───▶  │  (Client Mode)   │        │
│  │                  │       │                  │        │
│  │  - StdioTransport│       │  - StdioTransport│        │
│  │  - HTTPTransport │       │  - HTTPTransport │        │
│  │  - WebSocketTransport│   │  - WebSocketTransport │   │
│  └──────────────────┘       └──────────────────┘        │
│                                                          │
└─────────────────────────────────────────────────────────┘
```

## Transport 协议

所有传输实现都遵循 `Transport` 协议：

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

## 消息帧格式

对于 Stdio 传输，使用 LSP 标准的 Content-Length 头格式：

```
Content-Length: 123\r\n
\r\n
{"jsonrpc":"2.0",...}
```

HTTP 和 WebSocket 传输直接使用原始 JSON 负载。

## 要求

- macOS 14.0+
- Swift 6.0+

## 依赖

- [SwiftNIO](https://github.com/apple/swift-nio) - 网络基础
- [AsyncHTTPClient](https://github.com/swift-server/async-http-client) - HTTP 客户端
- [WebSocketKit](https://github.com/vapor/websocket-kit) - WebSocket 支持
- [swift-log](https://github.com/apple/swift-log) - 日志

## License

MIT
