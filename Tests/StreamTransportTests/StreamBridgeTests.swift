import Foundation
import Testing

@testable import StreamProxy
@testable import StreamTransportClient
@testable import StreamTransportServer

@Suite("Server Transport Tests")
struct ServerTransportTests {
  @Test("StdioTransport conforms to ServerTransport")
  func testStdioTransportIsServer() async {
    let transport = StdioTransport()
    let isRunning = await transport.isRunning
    #expect(isRunning == false)
  }

  @Test("HTTPTransport conforms to ServerTransport")
  func testHTTPTransportIsServer() async {
    let transport = HTTPTransport()
    let isRunning = await transport.isRunning
    #expect(isRunning == false)
  }

  @Test("WebSocketTransport conforms to ServerTransport")
  func testWebSocketTransportIsServer() async {
    let transport = WebSocketTransport()
    let isRunning = await transport.isRunning
    #expect(isRunning == false)
  }
}

@Suite("Client Transport Tests")
struct ClientTransportTests {
  @Test("URLSessionHTTPClientTransport conforms to ClientTransport")
  func testHTTPClientTransportIsClient() async {
    let transport = URLSessionHTTPClientTransport(host: "localhost", port: 8080)
    let isRunning = await transport.isRunning
    #expect(isRunning == false)
  }

  @Test("URLSessionWebSocketClientTransport conforms to ClientTransport")
  func testWebSocketClientTransportIsClient() async {
    let transport = URLSessionWebSocketClientTransport(host: "localhost", port: 8080)
    let isRunning = await transport.isRunning
    #expect(isRunning == false)
  }

  #if os(macOS) || os(Linux)
    @Test("ProcessTransport conforms to ClientTransport")
    func testProcessTransportIsClient() async {
      let transport = ProcessTransport(command: "echo", arguments: ["hello"])
      let isRunning = await transport.isRunning
      #expect(isRunning == false)
    }
  #endif
}

@Suite("Configuration Tests")
struct ConfigurationTests {
  @Test("HTTP server configuration creates correct URL")
  func testHTTPConfigURL() {
    let config = HTTPTransportConfiguration(
      host: "localhost", port: 8080, inPath: "/in", outPath: "/out")
    #expect(config.baseURL.absoluteString == "http://localhost:8080")
    #expect(config.inURL.absoluteString == "http://localhost:8080/in")
    #expect(config.outURL.absoluteString == "http://localhost:8080/out")
  }

  @Test("WebSocket server configuration creates correct URL")
  func testWebSocketConfigURL() {
    let config = WebSocketTransportConfiguration(
      host: "localhost", port: 9000, path: "/ws", useTLS: false)
    #expect(config.url.absoluteString == "ws://localhost:9000/ws")
  }

  @Test("WebSocket server configuration with TLS creates correct URL")
  func testWebSocketConfigTLSURL() {
    let config = WebSocketTransportConfiguration(
      host: "example.com", port: 443, path: "/ws", useTLS: true)
    #expect(config.url.absoluteString == "wss://example.com:443/ws")
  }

  @Test("ServerTransportType factory methods")
  func testServerTransportTypeFactoryMethods() {
    let httpType = ServerTransportType.http(host: "localhost", port: 3000)
    let wsType = ServerTransportType.webSocket(host: "localhost", port: 8080, path: "/ws")

    if case .http(let config) = httpType {
      #expect(config.host == "localhost")
      #expect(config.port == 3000)
      #expect(config.inPath == "/in")
      #expect(config.outPath == "/out")
    } else {
      Issue.record("Expected HTTP transport type")
    }

    if case .webSocket(let config) = wsType {
      #expect(config.host == "localhost")
      #expect(config.port == 8080)
      #expect(config.path == "/ws")
    } else {
      Issue.record("Expected WebSocket transport type")
    }
  }

  @Test("ClientTransportType factory methods")
  func testClientTransportTypeFactoryMethods() {
    let httpType = ClientTransportType.http(host: "localhost", port: 3000)
    let wsType = ClientTransportType.webSocket(
      host: "localhost", port: 8080, path: "/ws", useTLS: true)

    if case .http(let config) = httpType {
      #expect(config.baseURL.host == "localhost")
    } else {
      Issue.record("Expected HTTP client transport type")
    }

    if case .webSocket(let config) = wsType {
      #expect(config.url.host == "localhost")
    } else {
      Issue.record("Expected WebSocket client transport type")
    }
  }
}

@Suite("Proxy Tests")
struct ProxyTests {
  @Test("Proxy initializes correctly with transport types")
  func testProxyInitialization() async {
    let proxy = Proxy(
      inboundType: .stdio,
      outboundType: .http(host: "localhost", port: 8080)
    )

    let isRunning = await proxy.isRunning
    #expect(isRunning == false)
  }

  @Test("Proxy initializes correctly with configuration")
  func testProxyConfigurationInitialization() async {
    let config = ProxyConfiguration(
      inbound: .stdio,
      outbound: .webSocket(host: "localhost", port: 9000, path: "/ws", useTLS: false)
    )
    let proxy = Proxy(configuration: config)

    let isRunning = await proxy.isRunning
    #expect(isRunning == false)
  }

  @Test("Bridge typealias works")
  func testBridgeTypealias() async {
    let bridge = Bridge(
      inboundType: .stdio,
      outboundType: .http(host: "localhost", port: 8080)
    )

    let isRunning = await bridge.isRunning
    #expect(isRunning == false)
  }
}
