import Foundation
import Logging

/// Transport implementation that spawns a subprocess and communicates via its stdin/stdout
public actor ProcessTransport: Transport {
  public let mode: TransportMode = .client
  public private(set) var isRunning: Bool = false

  private let command: String
  private let arguments: [String]
  private let logger: Logger?

  private var process: Process?
  private var stdinPipe: Pipe?
  private var stdoutPipe: Pipe?
  private var stderrPipe: Pipe?

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

  /// Initialize a process transport
  /// - Parameters:
  ///   - command: The command to execute
  ///   - arguments: Arguments to pass to the command
  ///   - logger: Optional logger instance
  public init(command: String, arguments: [String] = [], logger: Logger? = nil) {
    self.command = command
    self.arguments = arguments
    self.logger = logger
  }

  public func start() async throws {
    guard !isRunning else {
      throw TransportError.alreadyStarted
    }

    _ = messages  // Initialize messages stream

    let process = Process()
    let stdinPipe = Pipe()
    let stdoutPipe = Pipe()
    let stderrPipe = Pipe()

    process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
    process.arguments = [command] + arguments
    process.standardInput = stdinPipe
    process.standardOutput = stdoutPipe
    process.standardError = stderrPipe

    self.process = process
    self.stdinPipe = stdinPipe
    self.stdoutPipe = stdoutPipe
    self.stderrPipe = stderrPipe

    do {
      try process.run()
      isRunning = true
      logger?.info("Started process: \(command) \(arguments.joined(separator: " "))")

      // Start reading from stdout
      startReading()

      // Also log stderr
      startReadingStderr()
    } catch {
      throw TransportError.connectionFailed(
        "Failed to start process: \(error.localizedDescription)")
    }
  }

  public func stop() async throws {
    guard isRunning else { return }

    isRunning = false
    readTask?.cancel()
    readTask = nil

    process?.terminate()
    process?.waitUntilExit()
    process = nil

    stdinPipe = nil
    stdoutPipe = nil
    stderrPipe = nil

    messagesContinuation?.finish()
    logger?.info("Process transport stopped")
  }

  public func send(_ data: Data) async throws {
    guard isRunning, let stdinPipe = stdinPipe else {
      throw TransportError.notStarted
    }

    let framedData = MessageFraming.frame(data)

    do {
      try stdinPipe.fileHandleForWriting.write(contentsOf: framedData)
      logger?.debug("Sent \(data.count) bytes to process stdin")
    } catch {
      throw TransportError.sendFailed(
        "Failed to write to process stdin: \(error.localizedDescription)")
    }
  }

  // MARK: - Private

  private func startReading() {
    guard let stdoutPipe = stdoutPipe else { return }

    readTask = Task { [weak self] in
      guard let self else { return }

      var buffer = Data()
      let fileHandle = stdoutPipe.fileHandleForReading

      while !Task.isCancelled {
        let chunk = fileHandle.availableData

        if chunk.isEmpty {
          // EOF
          break
        }

        buffer.append(chunk)

        // Try to parse complete messages
        while let message = await self.extractMessage(from: &buffer) {
          await self.yieldMessage(message)
        }
      }

      await self.finishMessages()
    }
  }

  private func startReadingStderr() {
    guard let stderrPipe = stderrPipe else { return }

    Task { [weak self] in
      let fileHandle = stderrPipe.fileHandleForReading

      while !Task.isCancelled {
        let chunk = fileHandle.availableData

        if chunk.isEmpty {
          break
        }

        if let text = String(data: chunk, encoding: .utf8) {
          await self?.logError("Process stderr: \(text)")
        }
      }
    }
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

  private func yieldMessage(_ data: Data) {
    messagesContinuation?.yield(data)
    logger?.debug("Received \(data.count) bytes from process stdout")
  }

  private func finishMessages() {
    messagesContinuation?.finish()
  }

  private func logError(_ message: String) {
    logger?.error("\(message)")
  }
}
