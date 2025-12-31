import Foundation
import Logging
import StreamTransportClient
import StreamTransportCore
import StreamTransportServer

/// Configuration for the Stream Bridge
public struct ProxyConfiguration: Sendable {
  public let inbound: ServerTransportType
  public let outbound: ClientTransportType

  public init(inbound: ServerTransportType, outbound: ClientTransportType) {
    self.inbound = inbound
    self.outbound = outbound
  }
}

/// Server transport types (for inbound connections)
public enum ServerTransportType: Sendable {
  /// Standard input/output transport
  case stdio
  /// HTTP server transport
  case http(HTTPTransportConfiguration)
  /// WebSocket server transport
  case webSocket(WebSocketTransportConfiguration)
}

/// Client transport types (for outbound connections)
public enum ClientTransportType: Sendable {
  /// HTTP client transport (using URLSession)
  case http(URLSessionHTTPClientConfiguration)
  /// WebSocket client transport (using URLSession)
  case webSocket(URLSessionWebSocketClientConfiguration)
  /// Process transport (spawns a subprocess)
  case process(command: String, arguments: [String])
}

/// Typealias for backward compatibility
public typealias Bridge = Proxy

/// Stream Bridge that forwards data between a server transport and a client transport
public actor Proxy {
  private let inbound: any ServerTransport
  private let outbound: any ClientTransport
  private let logger: Logger?

  private var forwardTask: Task<Void, Never>?
  private var responseTask: Task<Void, Never>?

  public private(set) var isRunning: Bool = false

  /// Initialize a bridge with specific transport instances
  /// - Parameters:
  ///   - inbound: Server transport receiving incoming data
  ///   - outbound: Client transport sending data to backend
  ///   - logger: Optional logger instance
  public init(inbound: any ServerTransport, outbound: any ClientTransport, logger: Logger? = nil) {
    self.inbound = inbound
    self.outbound = outbound
    self.logger = logger
  }

  /// Initialize a bridge with transport types and configuration
  /// - Parameters:
  ///   - inboundType: Server transport type for inbound connections
  ///   - outboundType: Client transport type for outbound connections
  ///   - logger: Optional logger instance
  public init(
    inboundType: ServerTransportType,
    outboundType: ClientTransportType,
    logger: Logger? = nil
  ) {
    self.inbound = Self.createServerTransport(type: inboundType, logger: logger)
    self.outbound = Self.createClientTransport(type: outboundType, logger: logger)
    self.logger = logger
  }

  /// Initialize a bridge from configuration
  /// - Parameters:
  ///   - configuration: Bridge configuration
  ///   - logger: Optional logger instance
  public init(configuration: ProxyConfiguration, logger: Logger? = nil) {
    self.inbound = Self.createServerTransport(type: configuration.inbound, logger: logger)
    self.outbound = Self.createClientTransport(type: configuration.outbound, logger: logger)
    self.logger = logger
  }

  /// Start the bridge
  public func start() async throws {
    guard !isRunning else { return }

    logger?.info("Starting Stream Bridge...")

    // Start both transports
    try await inbound.start()
    try await outbound.start()

    isRunning = true

    // Start forwarding data
    startDataForwarding()

    logger?.info("Stream Bridge started")
  }

  /// Stop the bridge
  public func stop() async throws {
    guard isRunning else { return }

    logger?.info("Stopping Stream Bridge...")

    forwardTask?.cancel()
    responseTask?.cancel()
    forwardTask = nil
    responseTask = nil

    try await inbound.stop()
    try await outbound.stop()

    isRunning = false

    logger?.info("Stream Bridge stopped")
  }

  /// Run the bridge until cancelled
  public func run() async throws {
    try await start()

    // Wait indefinitely until cancelled
    while isRunning {
      try await Task.sleep(for: .seconds(1))
    }
  }

  /// Bridge two transports and run until cancelled
  /// - Parameters:
  ///   - source: Server transport (inbound)
  ///   - destination: Client transport (outbound)
  ///   - logger: Optional logger
  public static func bridge(
    from source: any ServerTransport,
    to destination: any ClientTransport,
    logger: Logger? = nil
  ) async throws {
    let proxy = Proxy(inbound: source, outbound: destination, logger: logger)
    try await proxy.run()
  }

  // MARK: - Private

  private static func createServerTransport(type: ServerTransportType, logger: Logger?)
    -> any ServerTransport
  {
    switch type {
    case .stdio:
      return StdioTransport(logger: logger)
    case .http(let config):
      return HTTPTransport(config: config, logger: logger)
    case .webSocket(let config):
      return WebSocketTransport(config: config, logger: logger)
    }
  }

  private static func createClientTransport(type: ClientTransportType, logger: Logger?)
    -> any ClientTransport
  {
    switch type {
    case .http(let config):
      return URLSessionHTTPClientTransport(config: config, logger: logger)
    case .webSocket(let config):
      return URLSessionWebSocketClientTransport(config: config, logger: logger)
    case .process(let command, let arguments):
      return ProcessTransport(command: command, arguments: arguments, logger: logger)
    }
  }

  private func startDataForwarding() {
    // Forward inbound data to outbound
    forwardTask = Task {
      for await data in await inbound.messages {
        do {
          logger?.debug("Forwarding: \(data.count) bytes")
          try await outbound.send(data)
        } catch {
          logger?.error("Failed to forward: \(error)")
        }
      }
    }

    // Forward outbound responses back to inbound
    responseTask = Task {
      for await data in await outbound.messages {
        do {
          logger?.debug("Forwarding response: \(data.count) bytes")
          try await inbound.send(data)
        } catch {
          logger?.error("Failed to forward response: \(error)")
        }
      }
    }
  }
}
