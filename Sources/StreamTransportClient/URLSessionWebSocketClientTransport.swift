import Foundation
import Logging
import StreamTransportCore

/// Configuration for URLSession WebSocket client transport
public struct URLSessionWebSocketClientConfiguration: Sendable {
  public let url: URL
  public let pingInterval: TimeInterval?

  public init(url: URL, pingInterval: TimeInterval? = 30) {
    self.url = url
    self.pingInterval = pingInterval
  }

  public init(
    host: String,
    port: Int,
    path: String = "/",
    useTLS: Bool = false,
    pingInterval: TimeInterval? = 30
  ) {
    let scheme = useTLS ? "wss" : "ws"
    self.url = URL(string: "\(scheme)://\(host):\(port)\(path)")!
    self.pingInterval = pingInterval
  }
}

/// WebSocket client transport using URLSession
///
/// This transport connects to a WebSocket server and provides
/// bidirectional streaming communication.
public actor URLSessionWebSocketClientTransport: ClientTransport {
  public private(set) var isRunning: Bool = false

  private let config: URLSessionWebSocketClientConfiguration
  private let logger: Logger?
  private var session: URLSession?
  private var webSocketTask: URLSessionWebSocketTask?
  private var receiveTask: Task<Void, Never>?
  private var pingTask: Task<Void, Never>?
  private var messagesContinuation: AsyncStream<Data>.Continuation?
  private var _messages: AsyncStream<Data>?

  public var messages: AsyncStream<Data> {
    if let existing = _messages {
      return existing
    }
    let (stream, continuation) = AsyncStream<Data>.makeStream()
    self.messagesContinuation = continuation
    self._messages = stream
    return stream
  }

  /// Initialize a WebSocket client transport
  /// - Parameters:
  ///   - config: WebSocket client configuration
  ///   - logger: Optional logger instance
  public init(config: URLSessionWebSocketClientConfiguration, logger: Logger? = nil) {
    self.config = config
    self.logger = logger
  }

  /// Convenience initializer with URL components
  public init(
    host: String,
    port: Int,
    path: String = "/",
    useTLS: Bool = false,
    logger: Logger? = nil
  ) {
    self.config = URLSessionWebSocketClientConfiguration(
      host: host,
      port: port,
      path: path,
      useTLS: useTLS
    )
    self.logger = logger
  }

  public func start() async throws {
    guard !isRunning else {
      throw TransportError.alreadyStarted
    }

    let configuration = URLSessionConfiguration.default
    session = URLSession(configuration: configuration)

    guard let session = session else {
      throw TransportError.connectionFailed("Failed to create URLSession")
    }

    let task = session.webSocketTask(with: config.url)
    self.webSocketTask = task
    task.resume()

    isRunning = true
    _ = messages  // Initialize messages stream

    // Start receiving messages
    startReceiving()

    // Start ping loop if configured
    if let interval = config.pingInterval {
      startPinging(interval: interval)
    }

    logger?.info("URLSessionWebSocketClientTransport started, connected to \(config.url)")
  }

  public func stop() async throws {
    guard isRunning else { return }

    isRunning = false
    receiveTask?.cancel()
    pingTask?.cancel()
    receiveTask = nil
    pingTask = nil

    webSocketTask?.cancel(with: .goingAway, reason: nil)
    webSocketTask = nil
    session?.invalidateAndCancel()
    session = nil

    messagesContinuation?.finish()

    logger?.info("URLSessionWebSocketClientTransport stopped")
  }

  public func send(_ data: Data) async throws {
    guard isRunning, let webSocketTask = webSocketTask else {
      throw TransportError.notStarted
    }

    let message = URLSessionWebSocketTask.Message.data(data)
    try await webSocketTask.send(message)

    logger?.debug("Sent \(data.count) bytes via WebSocket")
  }

  /// Send a text message
  public func sendText(_ text: String) async throws {
    guard isRunning, let webSocketTask = webSocketTask else {
      throw TransportError.notStarted
    }

    let message = URLSessionWebSocketTask.Message.string(text)
    try await webSocketTask.send(message)

    logger?.debug("Sent text message: \(text.prefix(100))...")
  }

  // MARK: - Private

  private func startReceiving() {
    receiveTask = Task { [weak self] in
      await self?.receiveLoop()
    }
  }

  private func receiveLoop() async {
    guard let webSocketTask = webSocketTask else { return }

    while isRunning && !Task.isCancelled {
      do {
        let message = try await webSocketTask.receive()

        switch message {
        case .data(let data):
          messagesContinuation?.yield(data)
          logger?.debug("Received \(data.count) bytes via WebSocket")

        case .string(let text):
          let data = Data(text.utf8)
          messagesContinuation?.yield(data)
          logger?.debug("Received text message: \(text.prefix(100))...")

        @unknown default:
          logger?.warning("Unknown WebSocket message type")
        }

      } catch {
        if !Task.isCancelled {
          logger?.error("WebSocket receive error: \(error)")
          break
        }
      }
    }

    messagesContinuation?.finish()
  }

  private func startPinging(interval: TimeInterval) {
    pingTask = Task { [weak self] in
      while let self = self, await self.isRunning && !Task.isCancelled {
        try? await Task.sleep(for: .seconds(interval))

        if let task = await self.webSocketTask {
          task.sendPing { error in
            if let error = error {
              Task {
                await self.logger?.warning("WebSocket ping failed: \(error)")
              }
            }
          }
        }
      }
    }
  }
}
