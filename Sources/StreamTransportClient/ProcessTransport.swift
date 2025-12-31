#if os(macOS) || os(Linux)

  import Foundation
  import Logging
  import StreamTransportCore

  /// Transport implementation that spawns a subprocess and communicates via its stdin/stdout
  ///
  /// This transport is only available on macOS and Linux where the Process API is supported.
  public actor ProcessTransport: ClientTransport {
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

      process.terminationHandler = { [weak self] process in
        Task { [weak self] in
          await self?.handleTermination(process)
        }
      }

      do {
        try process.run()
        isRunning = true
        logger?.info(
          "Started process: \(command) \(arguments.joined(separator: " ")) (PID: \(process.processIdentifier))"
        )

        // Start reading from stdout
        startReading()

        // Also forward stderr
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

      process?.terminationHandler = nil
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

      logger?.debug("Sending \(data.count) bytes to process stdin...")

      // Write raw bytes to process stdin
      do {
        try stdinPipe.fileHandleForWriting.write(contentsOf: data)
        logger?.debug("Sent \(data.count) bytes to process stdin")
      } catch {
        throw TransportError.sendFailed(
          "Failed to write to process stdin: \(error.localizedDescription)")
      }
    }

    private func handleTermination(_ process: Process) {
      logger?.info("Process exited with code: \(process.terminationStatus)")
      isRunning = false
      messagesContinuation?.finish()
    }

    // MARK: - Private

    private func startReading() {
      guard let stdoutPipe = stdoutPipe, let continuation = messagesContinuation else { return }
      let logger = self.logger

      readTask = Task.detached {
        let fileHandle = stdoutPipe.fileHandleForReading

        while !Task.isCancelled {
          let chunk = fileHandle.availableData

          if chunk.isEmpty {
            // EOF
            break
          }

          continuation.yield(chunk)
          logger?.debug("Received \(chunk.count) bytes from process stdout")
        }

        continuation.finish()
      }
    }

    private func startReadingStderr() {
      guard let stderrPipe = stderrPipe else { return }
      let logger = self.logger

      Task.detached {
        let fileHandle = stderrPipe.fileHandleForReading

        while !Task.isCancelled {
          let chunk = fileHandle.availableData

          if chunk.isEmpty {
            break
          }

          // Forward subprocess stderr to parent's stderr
          try? FileHandle.standardError.write(contentsOf: chunk)

          // Also log if logger is available
          if let text = String(data: chunk, encoding: .utf8) {
            logger?.error("Process stderr: \(text)")
          } else {
            logger?.error("Process stderr: <binary data: \(chunk.count) bytes>")
          }
        }
      }
    }
  }

#endif
