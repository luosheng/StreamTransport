import Foundation
import Logging

/// Transport implementation using stdin/stdout for JSON-RPC communication
public actor StdioTransport: Transport {
  public let mode: TransportMode
  public private(set) var isRunning: Bool = false

  private let logger: Logger?
  private var messagesContinuation: AsyncStream<Data>.Continuation?
  private var _messages: AsyncStream<Data>?
  private var readTask: Task<Void, Never>?

  public var messages: AsyncStream<Data> {
    if let existing = _messages {
      return existing
    }
    let (stream, continuation) = AsyncStream<Data>.makeStream()
    self.messagesContinuation = continuation
    self._messages = stream
    return stream
  }

  /// Initialize a stdio transport
  /// - Parameter mode: .server reads from stdin, .client writes to stdout
  public init(mode: TransportMode = .server, logger: Logger? = nil) {
    self.mode = mode
    self.logger = logger
  }

  public func start() async throws {
    guard !isRunning else {
      throw TransportError.alreadyStarted
    }

    isRunning = true
    logger?.info("StdioTransport started in \(mode) mode")

    if mode == .server {
      // Initialize the messages stream if not already done
      _ = messages
      startReading()
    }
  }

  public func stop() async throws {
    guard isRunning else { return }

    isRunning = false
    readTask?.cancel()
    readTask = nil
    messagesContinuation?.finish()
    logger?.info("StdioTransport stopped")
  }

  public func send(_ data: Data) async throws {
    guard isRunning else {
      throw TransportError.notStarted
    }

    let framedData = MessageFraming.frame(data)

    // Write to stdout
    try framedData.withUnsafeBytes { buffer in
      guard let baseAddress = buffer.baseAddress else { return }
      let written = fwrite(baseAddress, 1, buffer.count, stdout)
      if written != buffer.count {
        throw TransportError.sendFailed("Failed to write all bytes to stdout")
      }
      fflush(stdout)
    }

    logger?.debug("Sent \(data.count) bytes via stdout")
  }

  // MARK: - Private

  private func startReading() {
    readTask = Task { [weak self] in
      await self?.readLoop()
    }
  }

  private func readLoop() async {
    var buffer = Data()
    let chunkSize = 4096
    var chunk = [UInt8](repeating: 0, count: chunkSize)

    while !Task.isCancelled && isRunning {
      // Read from stdin
      let bytesRead = fread(&chunk, 1, chunkSize, stdin)

      if bytesRead > 0 {
        buffer.append(contentsOf: chunk[0..<bytesRead])

        // Try to parse complete messages
        while let message = extractMessage(from: &buffer) {
          messagesContinuation?.yield(message)
          logger?.debug("Received \(message.count) bytes via stdin")
        }
      } else if feof(stdin) != 0 {
        logger?.info("stdin closed (EOF)")
        break
      } else if ferror(stdin) != 0 {
        logger?.error("Error reading from stdin")
        break
      }

      // Small delay to prevent busy-waiting
      try? await Task.sleep(for: .milliseconds(10))
    }

    messagesContinuation?.finish()
  }

  private func extractMessage(from buffer: inout Data) -> Data? {
    guard let (contentLength, headerEnd) = MessageFraming.parseHeader(buffer) else {
      return nil
    }

    let totalLength = headerEnd + contentLength
    guard buffer.count >= totalLength else {
      return nil
    }

    let messageData = buffer.subdata(in: headerEnd..<totalLength)
    buffer.removeSubrange(0..<totalLength)

    return messageData
  }
}
