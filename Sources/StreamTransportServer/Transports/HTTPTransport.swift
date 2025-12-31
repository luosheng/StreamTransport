import AsyncHTTPClient
import Foundation
import Logging
import NIOCore
import NIOHTTP1
import NIOPosix
import StreamTransportCore

/// Configuration for HTTP server transport
public struct HTTPTransportConfiguration: Sendable {
  public let host: String
  public let port: Int
  public let inPath: String
  public let outPath: String

  public init(
    host: String = "127.0.0.1",
    port: Int = 8080,
    inPath: String = "/in",
    outPath: String = "/out"
  ) {
    self.host = host
    self.port = port
    self.inPath = inPath
    self.outPath = outPath
  }

  public var baseURL: URL {
    URL(string: "http://\(host):\(port)")!
  }

  public var inURL: URL {
    URL(string: "http://\(host):\(port)\(inPath)")!
  }

  public var outURL: URL {
    URL(string: "http://\(host):\(port)\(outPath)")!
  }
}

/// HTTP server transport implementation using SwiftNIO
///
/// This transport provides two endpoints:
/// - `/in` (POST): Receives data from clients, forwarded to the `messages` stream
/// - `/out` (GET): Streams outgoing data to clients using chunked transfer encoding
///
/// This design aligns semantically with stdio:
/// - `/in` ≈ stdin (clients write data to the server)
/// - `/out` ≈ stdout (server streams data to clients)
public actor HTTPTransport: ServerTransport {
  public private(set) var isRunning: Bool = false

  private let config: HTTPTransportConfiguration
  private let logger: Logger
  private var messagesContinuation: AsyncStream<Data>.Continuation?
  private var _messages: AsyncStream<Data>?

  private var eventLoopGroup: EventLoopGroup?
  private var serverChannel: Channel?
  private var outputHandler: HTTPServerOutputHandler?

  public var messages: AsyncStream<Data> {
    if let existing = _messages {
      return existing
    }
    let (stream, continuation) = AsyncStream<Data>.makeStream()
    self.messagesContinuation = continuation
    self._messages = stream
    return stream
  }

  /// Initialize an HTTP server transport
  /// - Parameters:
  ///   - config: HTTP configuration (host, port, paths)
  ///   - logger: Optional logger instance
  public init(
    config: HTTPTransportConfiguration = HTTPTransportConfiguration(),
    logger: Logger? = nil
  ) {
    self.config = config
    self.logger = logger ?? Logger(label: "stream-bridge.http")
  }

  public func start() async throws {
    guard !isRunning else {
      throw TransportError.alreadyStarted
    }

    isRunning = true
    try await startServer()

    logger.info("HTTPTransport started on \(config.host):\(config.port)")
  }

  public func stop() async throws {
    guard isRunning else { return }

    isRunning = false

    outputHandler?.close()
    try await serverChannel?.close()
    try await eventLoopGroup?.shutdownGracefully()
    serverChannel = nil
    eventLoopGroup = nil
    outputHandler = nil

    messagesContinuation?.finish()
    logger.info("HTTPTransport stopped")
  }

  public func send(_ data: Data) async throws {
    guard isRunning else {
      throw TransportError.notStarted
    }

    // Push data to connected /out clients
    outputHandler?.send(data)
    logger.debug("Queued \(data.count) bytes for /out streaming")
  }

  // MARK: - Server Implementation

  private func startServer() async throws {
    _ = messages  // Initialize messages stream

    let group = MultiThreadedEventLoopGroup(numberOfThreads: System.coreCount)
    self.eventLoopGroup = group

    let handler = HTTPServerOutputHandler()
    self.outputHandler = handler

    let inPath = config.inPath
    let outPath = config.outPath
    let onMessage: @Sendable (Data) async -> Void = { [weak self] data in
      guard let self else { return }
      await self.handleIncomingMessage(data)
    }

    let bootstrap = ServerBootstrap(group: group)
      .serverChannelOption(.backlog, value: 256)
      .serverChannelOption(.socketOption(.so_reuseaddr), value: 1)
      .childChannelInitializer { channel in
        channel.pipeline.configureHTTPServerPipeline().flatMap {
          channel.pipeline.addHandler(
            HTTPServerRequestHandler(
              inPath: inPath,
              outPath: outPath,
              outputHandler: handler,
              onMessage: onMessage
            )
          )
        }
      }
      .childChannelOption(.socketOption(.so_reuseaddr), value: 1)
      .childChannelOption(.maxMessagesPerRead, value: 16)

    let channel = try await bootstrap.bind(host: config.host, port: config.port).get()
    self.serverChannel = channel
  }

  private func handleIncomingMessage(_ data: Data) {
    messagesContinuation?.yield(data)
    logger.debug("Received data on /in: \(data.count) bytes")
  }
}

// MARK: - HTTP Server Output Handler

/// Manages streaming output to connected /out clients
private final class HTTPServerOutputHandler: @unchecked Sendable {
  private let lock = NSLock()
  private var channels: [ObjectIdentifier: Channel] = [:]
  private var isClosed = false

  func addChannel(_ channel: Channel) {
    lock.lock()
    defer { lock.unlock() }
    guard !isClosed else { return }
    channels[ObjectIdentifier(channel)] = channel
  }

  func removeChannel(_ channel: Channel) {
    lock.lock()
    defer { lock.unlock() }
    channels.removeValue(forKey: ObjectIdentifier(channel))
  }

  func send(_ data: Data) {
    lock.lock()
    let currentChannels = Array(channels.values)
    lock.unlock()

    for channel in currentChannels {
      // Send as chunked data
      var buffer = channel.allocator.buffer(capacity: data.count)
      buffer.writeBytes(data)
      channel.writeAndFlush(HTTPServerResponsePart.body(.byteBuffer(buffer)), promise: nil)
    }
  }

  func close() {
    lock.lock()
    isClosed = true
    let currentChannels = Array(channels.values)
    channels.removeAll()
    lock.unlock()

    for channel in currentChannels {
      channel.writeAndFlush(HTTPServerResponsePart.end(nil), promise: nil)
    }
  }
}

// MARK: - HTTP Server Request Handler

private final class HTTPServerRequestHandler: ChannelInboundHandler, @unchecked Sendable {
  typealias InboundIn = HTTPServerRequestPart
  typealias OutboundOut = HTTPServerResponsePart

  private let inPath: String
  private let outPath: String
  private let outputHandler: HTTPServerOutputHandler
  private let onMessage: @Sendable (Data) async -> Void

  private var requestBody = Data()
  private var currentPath: String = ""
  private var currentMethod: HTTPMethod = .GET
  private var isStreamingOut = false

  init(
    inPath: String,
    outPath: String,
    outputHandler: HTTPServerOutputHandler,
    onMessage: @escaping @Sendable (Data) async -> Void
  ) {
    self.inPath = inPath
    self.outPath = outPath
    self.outputHandler = outputHandler
    self.onMessage = onMessage
  }

  func channelRead(context: ChannelHandlerContext, data: NIOAny) {
    let reqPart = unwrapInboundIn(data)

    switch reqPart {
    case .head(let requestHead):
      currentPath = requestHead.uri
      currentMethod = requestHead.method
      requestBody = Data()
      isStreamingOut = false

    case .body(let buffer):
      var buf = buffer
      if let bytes = buf.readBytes(length: buf.readableBytes) {
        requestBody.append(contentsOf: bytes)
      }

    case .end:
      handleRequest(context: context)
    }
  }

  private func handleRequest(context: ChannelHandlerContext) {
    // Route based on path and method
    if currentMethod == .POST && currentPath.hasPrefix(inPath) {
      handleInRequest(context: context)
    } else if currentMethod == .GET && currentPath.hasPrefix(outPath) {
      handleOutRequest(context: context)
    } else {
      sendNotFound(context: context)
    }
  }

  // MARK: - /in Endpoint (POST)

  private func handleInRequest(context: ChannelHandlerContext) {
    let body = requestBody
    let onMessage = self.onMessage

    // Process the request asynchronously
    Task {
      await onMessage(body)
    }

    // Send acknowledgment response
    let responseBody = Data("{\"status\":\"received\"}".utf8)

    var headers = HTTPHeaders()
    headers.add(name: "Content-Type", value: "application/json")
    headers.add(name: "Content-Length", value: String(responseBody.count))

    let head = HTTPResponseHead(version: .http1_1, status: .ok, headers: headers)
    context.write(wrapOutboundOut(.head(head)), promise: nil)

    var buffer = context.channel.allocator.buffer(capacity: responseBody.count)
    buffer.writeBytes(responseBody)
    context.write(wrapOutboundOut(.body(.byteBuffer(buffer))), promise: nil)

    context.writeAndFlush(wrapOutboundOut(.end(nil)), promise: nil)
  }

  // MARK: - /out Endpoint (GET, Streaming)

  private func handleOutRequest(context: ChannelHandlerContext) {
    isStreamingOut = true

    // Send chunked response headers
    var headers = HTTPHeaders()
    headers.add(name: "Content-Type", value: "application/octet-stream")
    headers.add(name: "Transfer-Encoding", value: "chunked")
    headers.add(name: "Cache-Control", value: "no-cache")
    headers.add(name: "Connection", value: "keep-alive")

    let head = HTTPResponseHead(version: .http1_1, status: .ok, headers: headers)
    context.writeAndFlush(wrapOutboundOut(.head(head)), promise: nil)

    // Register this channel to receive output data
    outputHandler.addChannel(context.channel)
  }

  // MARK: - 404 Not Found

  private func sendNotFound(context: ChannelHandlerContext) {
    let responseBody = Data("{\"error\":\"Not Found\"}".utf8)

    var headers = HTTPHeaders()
    headers.add(name: "Content-Type", value: "application/json")
    headers.add(name: "Content-Length", value: String(responseBody.count))

    let head = HTTPResponseHead(version: .http1_1, status: .notFound, headers: headers)
    context.write(wrapOutboundOut(.head(head)), promise: nil)

    var buffer = context.channel.allocator.buffer(capacity: responseBody.count)
    buffer.writeBytes(responseBody)
    context.write(wrapOutboundOut(.body(.byteBuffer(buffer))), promise: nil)

    context.writeAndFlush(wrapOutboundOut(.end(nil)), promise: nil)
  }

  // MARK: - Channel Lifecycle

  func channelInactive(context: ChannelHandlerContext) {
    if isStreamingOut {
      outputHandler.removeChannel(context.channel)
    }
    context.fireChannelInactive()
  }
}
