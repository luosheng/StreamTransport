import Foundation

// MARK: - Transport Protocol

/// Errors that can occur during transport operations
public enum TransportError: Error, Sendable {
  case notStarted
  case alreadyStarted
  case connectionFailed(String)
  case sendFailed(String)
  case invalidMessage(String)
  case timeout
  case closed
}

/// Base protocol defining a transport mechanism for streaming data
public protocol Transport: Actor {
  /// Whether the transport is currently running
  var isRunning: Bool { get }

  /// Start the transport
  func start() async throws

  /// Stop the transport
  func stop() async throws

  /// Send data through the transport
  func send(_ data: Data) async throws

  /// Stream of incoming data
  var messages: AsyncStream<Data> { get }
}

// MARK: - Server Transport

/// A transport that listens for and accepts incoming connections/data
///
/// Server transports are used as the inbound side of a proxy, receiving
/// data from external clients.
public protocol ServerTransport: Transport {}

// MARK: - Client Transport

/// A transport that connects to a remote endpoint
///
/// Client transports are used as the outbound side of a proxy, sending
/// data to backend services.
public protocol ClientTransport: Transport {}
