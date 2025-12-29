import Foundation
import Logging

/// Configuration for the JSON-RPC Proxy
public struct ProxyConfiguration: Sendable {
  public let inbound: TransportType
  public let outbound: TransportType

  public init(inbound: TransportType, outbound: TransportType) {
    self.inbound = inbound
    self.outbound = outbound
  }
}

/// Type of transport with associated configuration
public enum TransportType: Sendable {
  case stdio
  case http(HTTPTransportConfiguration)
  case webSocket(WebSocketTransportConfiguration)

  /// Create default HTTP configuration
  public static func http(host: String = "127.0.0.1", port: Int = 8080, path: String = "/")
    -> TransportType
  {
    .http(HTTPTransportConfiguration(host: host, port: port, path: path))
  }

  /// Create default WebSocket configuration
  public static func webSocket(
    host: String = "127.0.0.1", port: Int = 8080, path: String = "/", useTLS: Bool = false
  ) -> TransportType {
    .webSocket(WebSocketTransportConfiguration(host: host, port: port, path: path, useTLS: useTLS))
  }
}

/// JSON-RPC Proxy that forwards messages between two transports
public actor Proxy {
  private let inbound: any Transport
  private let outbound: any Transport
  private let logger: Logger?

  private var forwardTask: Task<Void, Never>?
  private var responseTask: Task<Void, Never>?

  public private(set) var isRunning: Bool = false

  /// Initialize a proxy with specific transport instances
  /// - Parameters:
  ///   - inbound: Transport receiving incoming messages (server mode)
  ///   - outbound: Transport sending messages to backend (client mode)
  ///   - logger: Optional logger instance
  public init(inbound: any Transport, outbound: any Transport, logger: Logger? = nil) {
    self.inbound = inbound
    self.outbound = outbound
    self.logger = logger
  }

  /// Initialize a proxy with transport types and configuration
  /// - Parameters:
  ///   - inboundType: Type and configuration for inbound transport
  ///   - outboundType: Type and configuration for outbound transport
  ///   - logger: Optional logger instance
  public init(inboundType: TransportType, outboundType: TransportType, logger: Logger? = nil) {
    self.inbound = Self.createTransport(type: inboundType, mode: .server, logger: logger)
    self.outbound = Self.createTransport(type: outboundType, mode: .client, logger: logger)
    self.logger = logger
  }

  /// Initialize a proxy from configuration
  /// - Parameters:
  ///   - configuration: Proxy configuration
  ///   - logger: Optional logger instance
  public init(configuration: ProxyConfiguration, logger: Logger? = nil) {
    self.inbound = Self.createTransport(type: configuration.inbound, mode: .server, logger: logger)
    self.outbound = Self.createTransport(
      type: configuration.outbound, mode: .client, logger: logger)
    self.logger = logger
  }

  /// Start the proxy
  public func start() async throws {
    guard !isRunning else { return }

    logger?.info("Starting JSON-RPC Proxy...")

    // Start both transports
    try await inbound.start()
    try await outbound.start()

    isRunning = true

    // Start forwarding messages
    startMessageForwarding()

    logger?.info("JSON-RPC Proxy started")
  }

  /// Stop the proxy
  public func stop() async throws {
    guard isRunning else { return }

    logger?.info("Stopping JSON-RPC Proxy...")

    forwardTask?.cancel()
    responseTask?.cancel()
    forwardTask = nil
    responseTask = nil

    try await inbound.stop()
    try await outbound.stop()

    isRunning = false

    logger?.info("JSON-RPC Proxy stopped")
  }

  /// Run the proxy until cancelled
  public func run() async throws {
    try await start()

    // Wait indefinitely until cancelled
    while isRunning {
      try await Task.sleep(for: .seconds(1))
    }
  }

  // MARK: - Private

  private static func createTransport(type: TransportType, mode: TransportMode, logger: Logger?)
    -> any Transport
  {
    switch type {
    case .stdio:
      return StdioTransport(mode: mode, logger: logger)
    case .http(let config):
      return HTTPTransport(mode: mode, config: config, logger: logger)
    case .webSocket(let config):
      return WebSocketTransport(mode: mode, config: config, logger: logger)
    }
  }

  private func startMessageForwarding() {
    // Forward inbound messages to outbound
    forwardTask = Task {
      for await message in await inbound.messages {
        do {
          logger?.debug("Forwarding request: \(message.count) bytes")
          try await outbound.send(message)
        } catch {
          logger?.error("Failed to forward request: \(error)")
        }
      }
    }

    // Forward outbound responses back to inbound
    responseTask = Task {
      for await message in await outbound.messages {
        do {
          logger?.debug("Forwarding response: \(message.count) bytes")
          try await inbound.send(message)
        } catch {
          logger?.error("Failed to forward response: \(error)")
        }
      }
    }
  }
}
