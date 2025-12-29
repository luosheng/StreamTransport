import Foundation
import JSONRPCProxy
import Logging

/// OpenCode ACP Proxy
///
/// This example demonstrates a stdio-to-process proxy that forwards
/// all JSON-RPC messages from stdin to the "opencode acp" command
/// and returns responses to stdout.
///
/// Set DEBUG=1 environment variable to enable logging to stderr.

@main
struct OpenCodeProxy {
  static func main() async throws {
    // Only enable logging if DEBUG environment variable is set
    let enableLogging = ProcessInfo.processInfo.environment["DEBUG"] != nil

    var logger: Logger?

    if enableLogging {
      LoggingSystem.bootstrap { label in
        var handler = StreamLogHandler.standardError(label: label)
        handler.logLevel = .debug
        return handler
      }
      logger = Logger(label: "opencode-proxy")
      logger?.info("Starting OpenCode ACP Proxy...")
    }

    // Create inbound transport (reads from stdin)
    let inbound = StdioTransport(mode: .server, logger: logger)

    // Create outbound transport (spawns "opencode acp" process)
    let outbound = ProcessTransport(
      command: "opencode",
      arguments: ["acp"],
      logger: logger
    )

    // Create and run the proxy
    let proxy = Proxy(inbound: inbound, outbound: outbound, logger: logger)

    if enableLogging {
      logger?.info("Proxy initialized. Forwarding stdin -> opencode acp -> stdout")
    }

    try await proxy.run()
  }
}
