import Foundation
import Logging
import StreamBridge

/// OpenCode ACP Proxy
///
/// A transparent proxy that bridges HTTP endpoints to "opencode acp" process.
@main
struct OpenCodeProxy {
  static func main() async throws {
    // Setup logging
    var logger = Logger(label: "opencode-proxy")
    logger.logLevel = .debug

    // Configuration
    let httpConfig = HTTPTransportConfiguration(
      host: "127.0.0.1",
      port: 3033,
      inPath: "/in",
      outPath: "/out"
    )

    logger.info("Starting OpenCode ACP Proxy...")

    // Create transports
    let httpTransport = HTTPTransport(mode: .server, config: httpConfig, logger: logger)
    let processTransport = ProcessTransport(
      command: "opencode",
      arguments: ["acp"],
      logger: logger
    )

    // Bridge them
    do {
      try await Proxy.bridge(from: httpTransport, to: processTransport, logger: logger)
    } catch {
      logger.error("Proxy failed: \(error)")
      exit(1)
    }
  }
}
