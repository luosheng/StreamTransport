import Foundation
import Logging
import StreamTransportCore

/// Configuration for URLSession HTTP client transport
public struct URLSessionHTTPClientConfiguration: Sendable {
  public let baseURL: URL
  public let inPath: String
  public let outPath: String
  public let timeoutInterval: TimeInterval

  public init(
    baseURL: URL,
    inPath: String = "/in",
    outPath: String = "/out",
    timeoutInterval: TimeInterval = 60
  ) {
    self.baseURL = baseURL
    self.inPath = inPath
    self.outPath = outPath
    self.timeoutInterval = timeoutInterval
  }

  public var inURL: URL {
    baseURL.appendingPathComponent(inPath)
  }

  public var outURL: URL {
    baseURL.appendingPathComponent(outPath)
  }
}

/// HTTP client transport using URLSession
///
/// This transport connects to an HTTP server and:
/// - POSTs data to the `/in` endpoint
/// - Streams responses from the `/out` endpoint
public actor URLSessionHTTPClientTransport: ClientTransport {
  public private(set) var isRunning: Bool = false

  private let config: URLSessionHTTPClientConfiguration
  private let logger: Logger?
  private var session: URLSession?
  private var streamTask: Task<Void, Never>?
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

  /// Initialize an HTTP client transport
  /// - Parameters:
  ///   - config: HTTP client configuration
  ///   - logger: Optional logger instance
  public init(config: URLSessionHTTPClientConfiguration, logger: Logger? = nil) {
    self.config = config
    self.logger = logger
  }

  /// Convenience initializer with URL components
  public init(
    host: String,
    port: Int,
    inPath: String = "/in",
    outPath: String = "/out",
    useTLS: Bool = false,
    logger: Logger? = nil
  ) {
    let scheme = useTLS ? "https" : "http"
    let baseURL = URL(string: "\(scheme)://\(host):\(port)")!
    self.config = URLSessionHTTPClientConfiguration(
      baseURL: baseURL,
      inPath: inPath,
      outPath: outPath
    )
    self.logger = logger
  }

  public func start() async throws {
    guard !isRunning else {
      throw TransportError.alreadyStarted
    }

    let configuration = URLSessionConfiguration.default
    configuration.timeoutIntervalForRequest = config.timeoutInterval
    session = URLSession(configuration: configuration)

    isRunning = true
    _ = messages  // Initialize messages stream

    // Start streaming from /out endpoint
    startStreaming()

    logger?.info("URLSessionHTTPClientTransport started, connecting to \(config.baseURL)")
  }

  public func stop() async throws {
    guard isRunning else { return }

    isRunning = false
    streamTask?.cancel()
    streamTask = nil
    session?.invalidateAndCancel()
    session = nil
    messagesContinuation?.finish()

    logger?.info("URLSessionHTTPClientTransport stopped")
  }

  public func send(_ data: Data) async throws {
    guard isRunning, let session = session else {
      throw TransportError.notStarted
    }

    var request = URLRequest(url: config.inURL)
    request.httpMethod = "POST"
    request.setValue("application/octet-stream", forHTTPHeaderField: "Content-Type")
    request.httpBody = data

    logger?.debug("Sending \(data.count) bytes to \(config.inURL)")

    let (responseData, response) = try await session.data(for: request)

    guard let httpResponse = response as? HTTPURLResponse else {
      throw TransportError.sendFailed("Invalid response type")
    }

    guard (200...299).contains(httpResponse.statusCode) else {
      throw TransportError.sendFailed("HTTP error: \(httpResponse.statusCode)")
    }

    logger?.debug("Sent \(data.count) bytes, received \(responseData.count) bytes response")
  }

  // MARK: - Private

  private func startStreaming() {
    streamTask = Task { [weak self] in
      await self?.streamLoop()
    }
  }

  private func streamLoop() async {
    guard let session = session else { return }

    while isRunning && !Task.isCancelled {
      do {
        var request = URLRequest(url: config.outURL)
        request.httpMethod = "GET"

        let (bytes, response) = try await session.bytes(for: request)

        guard let httpResponse = response as? HTTPURLResponse,
          (200...299).contains(httpResponse.statusCode)
        else {
          logger?.warning("Failed to connect to /out endpoint, retrying...")
          try await Task.sleep(for: .seconds(1))
          continue
        }

        logger?.debug("Connected to /out stream")

        // Read chunks from the stream
        var buffer = Data()
        for try await byte in bytes {
          buffer.append(byte)

          // Yield data in chunks (e.g., when we see newline or buffer gets large)
          if byte == UInt8(ascii: "\n") || buffer.count >= 4096 {
            if !buffer.isEmpty {
              messagesContinuation?.yield(buffer)
              logger?.debug("Received \(buffer.count) bytes from /out stream")
              buffer = Data()
            }
          }
        }

        // Yield any remaining data
        if !buffer.isEmpty {
          messagesContinuation?.yield(buffer)
        }

        logger?.info("/out stream ended")

      } catch {
        if !Task.isCancelled {
          logger?.error("Stream error: \(error), reconnecting...")
          try? await Task.sleep(for: .seconds(1))
        }
      }
    }
  }
}
