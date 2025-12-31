import Foundation
import Logging
import NIOCore
import NIOHTTP1
import NIOPosix
import NIOWebSocket
import StreamTransportCore
import WebSocketKit

/// Configuration for WebSocket server transport
public struct WebSocketTransportConfiguration: Sendable {
  public let host: String
  public let port: Int
  public let path: String
  public let useTLS: Bool

  public init(
    host: String = "127.0.0.1", port: Int = 8080, path: String = "/", useTLS: Bool = false
  ) {
    self.host = host
    self.port = port
    self.path = path
    self.useTLS = useTLS
  }

  public var url: URL {
    let scheme = useTLS ? "wss" : "ws"
    return URL(string: "\(scheme)://\(host):\(port)\(path)")!
  }
}

/// WebSocket server transport implementation using SwiftNIO
///
/// This transport creates a WebSocket server that accepts incoming connections
/// and provides bidirectional streaming communication.
public actor WebSocketTransport: ServerTransport {
  public private(set) var isRunning: Bool = false

  private let config: WebSocketTransportConfiguration
  private let logger: Logger
  private var messagesContinuation: AsyncStream<Data>.Continuation?
  private var _messages: AsyncStream<Data>?

  private var eventLoopGroup: EventLoopGroup?
  private var serverChannel: Channel?
  private var connectedClients: [WebSocket] = []

  public var messages: AsyncStream<Data> {
    if let existing = _messages {
      return existing
    }
    let (stream, continuation) = AsyncStream<Data>.makeStream()
    self.messagesContinuation = continuation
    self._messages = stream
    return stream
  }

  /// Initialize a WebSocket server transport
  /// - Parameters:
  ///   - config: WebSocket configuration
  ///   - logger: Optional logger instance
  public init(
    config: WebSocketTransportConfiguration = WebSocketTransportConfiguration(),
    logger: Logger? = nil
  ) {
    self.config = config
    self.logger = logger ?? Logger(label: "stream-bridge.websocket")
  }

  public func start() async throws {
    guard !isRunning else {
      throw TransportError.alreadyStarted
    }

    isRunning = true
    _ = messages  // Initialize messages stream

    try await startServer()

    logger.info("WebSocketTransport started on \(config.host):\(config.port)")
  }

  public func stop() async throws {
    guard isRunning else { return }

    isRunning = false

    for client in connectedClients {
      try await client.close()
    }
    connectedClients.removeAll()
    try await serverChannel?.close()
    try await eventLoopGroup?.shutdownGracefully()
    serverChannel = nil
    eventLoopGroup = nil

    messagesContinuation?.finish()
    logger.info("WebSocketTransport stopped")
  }

  public func send(_ data: Data) async throws {
    guard isRunning else {
      throw TransportError.notStarted
    }

    // Broadcast to all connected clients
    for client in connectedClients {
      try await client.send(Array(data))
    }

    logger.debug("Sent \(data.count) bytes via WebSocket to \(connectedClients.count) clients")
  }

  /// Send to a specific client
  public func send(_ data: Data, to client: WebSocket) async throws {
    try await client.send(Array(data))
  }

  // MARK: - Server Implementation

  private func startServer() async throws {
    let group = MultiThreadedEventLoopGroup(numberOfThreads: System.coreCount)
    self.eventLoopGroup = group

    let upgrader = NIOWebSocketServerUpgrader(
      shouldUpgrade: { channel, head in
        channel.eventLoop.makeSucceededFuture(HTTPHeaders())
      },
      upgradePipelineHandler: { channel, _ in
        WebSocket.server(on: channel) { [weak self] ws in
          guard let self else { return }
          Task {
            await self.handleNewClient(ws)
          }
        }
      }
    )

    let httpHandler = WebSocketHTTPHandler()

    let bootstrap = ServerBootstrap(group: group)
      .serverChannelOption(.backlog, value: 256)
      .serverChannelOption(.socketOption(.so_reuseaddr), value: 1)
      .childChannelInitializer { channel in
        let upgradeConfig: NIOHTTPServerUpgradeConfiguration = (
          upgraders: [upgrader],
          completionHandler: { _ in }
        )
        return channel.pipeline.configureHTTPServerPipeline(withServerUpgrade: upgradeConfig)
          .flatMap {
            channel.pipeline.addHandler(httpHandler)
          }
      }
      .childChannelOption(.socketOption(.so_reuseaddr), value: 1)

    let channel = try await bootstrap.bind(host: config.host, port: config.port).get()
    self.serverChannel = channel
  }

  private func handleNewClient(_ ws: WebSocket) {
    connectedClients.append(ws)
    logger.info("New WebSocket client connected. Total clients: \(connectedClients.count)")

    ws.onBinary { [weak self] _, buffer in
      guard let self else { return }
      let data = Data(buffer.readableBytesView)
      Task {
        await self.handleIncomingMessage(data)
      }
    }

    ws.onText { [weak self] _, text in
      guard let self else { return }
      let data = Data(text.utf8)
      Task {
        await self.handleIncomingMessage(data)
      }
    }

    ws.onClose.whenComplete { [weak self] _ in
      guard let self else { return }
      Task {
        await self.removeClient(ws)
      }
    }
  }

  private func removeClient(_ ws: WebSocket) {
    connectedClients.removeAll { $0 === ws }
    logger.info("WebSocket client disconnected. Total clients: \(connectedClients.count)")
  }

  private func handleIncomingMessage(_ data: Data) {
    messagesContinuation?.yield(data)
    logger.debug("Received \(data.count) bytes via WebSocket")
  }
}

// MARK: - HTTP Handler for WebSocket Upgrade

private final class WebSocketHTTPHandler: ChannelInboundHandler, RemovableChannelHandler,
  @unchecked Sendable
{
  typealias InboundIn = HTTPServerRequestPart
  typealias OutboundOut = HTTPServerResponsePart

  func channelRead(context: ChannelHandlerContext, data: NIOAny) {
    // Handle non-upgrade HTTP requests by returning 400
    let reqPart = unwrapInboundIn(data)

    if case .end = reqPart {
      var headers = HTTPHeaders()
      headers.add(name: "Content-Length", value: "0")
      let head = HTTPResponseHead(version: .http1_1, status: .badRequest, headers: headers)
      context.write(wrapOutboundOut(.head(head)), promise: nil)
      context.writeAndFlush(wrapOutboundOut(.end(nil)), promise: nil)
    }
  }
}
