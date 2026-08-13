import Foundation
import Swifter

/// Web server for remote session monitoring and access
/// Designed for access via Tailscale from mobile devices
final class WebServer {
    enum Mode: Equatable {
        case localOnly
        case remoteEnabled
    }

    static let shared = WebServer()

    private var server: HttpServer?
    private(set) var actualPort: UInt16 = 0
    private(set) var mode: Mode?
    private let basePort: UInt16 = 8080
    private let maxPortAttempts = 10

    private init() {}

    // MARK: - Public API

    /// Start the web server, automatically finding an available port.
    /// - Parameter mode: `.localOnly` for Codex local notify receiver, `.remoteEnabled` for vibeterm/WebSocket access.
    func start(mode requestedMode: Mode = .remoteEnabled) throws {
        if server != nil, mode == requestedMode {
            DebugLog.log("[WebServer] Already running on port \(actualPort) mode=\(requestedMode)")
            return
        }
        if server != nil, mode != requestedMode {
            stop()
        }

        let httpServer = HttpServer()
        configureRoutes(on: httpServer)
        configureListenAddress(for: requestedMode, on: httpServer)

        var lastError: Error?
        for offset in 0..<maxPortAttempts {
            let port = basePort + UInt16(offset)
            do {
                try httpServer.start(port, forceIPv4: shouldForceIPv4(for: requestedMode), priority: .default)
                server = httpServer
                mode = requestedMode
                actualPort = port
                AppSettings.webServerPort = Int(port)
                DebugLog.log("[WebServer] Started on port \(port) mode=\(requestedMode)")
                return
            } catch {
                lastError = error
                DebugLog.log("[WebServer] Port \(port) unavailable, trying next...")
            }
        }

        throw lastError ?? WebServerError.noAvailablePort
    }

    /// Stop the web server
    func stop() {
        let previousMode = mode
        server?.stop()
        server = nil
        let port = actualPort
        mode = nil
        actualPort = 0
        DebugLog.log("[WebServer] Stopped (was on port \(port), mode=\(String(describing: previousMode)))")
    }

    /// Check if server is running
    var isRunning: Bool {
        server != nil
    }

    /// True when remote access endpoints should be considered available to other devices.
    var isRemoteEnabled: Bool {
        mode == .remoteEnabled
    }

    // MARK: - Private

    private func configureRoutes(on httpServer: HttpServer) {
        // WebSocket /ws/sessions - Real-time session updates
        httpServer["/ws/sessions"] = websocket(
            connected: { wsSession in
                Task { @MainActor in
                    WebSocketManager.shared.subscribe(wsSession)
                }
            },
            disconnected: { wsSession in
                Task { @MainActor in
                    WebSocketManager.shared.unsubscribe(wsSession)
                }
            }
        )

        // POST /api/codex/status - Receive Codex notify events
        httpServer.POST["/api/codex/status"] = { request in
            let bodyData = Data(request.body)
            Task { @MainActor in
                CodexStatusReceiver.shared.handleEvent(bodyData)
            }
            return .ok(.text("received"))
        }
    }

    private func configureListenAddress(for mode: Mode, on httpServer: HttpServer) {
        switch mode {
        case .localOnly:
            // Keep Codex status ingestion available even when remote WebSocket is disabled.
            httpServer.listenAddressIPv4 = "127.0.0.1"
            httpServer.listenAddressIPv6 = nil
        case .remoteEnabled:
            // nil means bind all interfaces.
            httpServer.listenAddressIPv4 = nil
            httpServer.listenAddressIPv6 = nil
        }
    }

    private func shouldForceIPv4(for mode: Mode) -> Bool {
        switch mode {
        case .localOnly:
            return true
        case .remoteEnabled:
            return false
        }
    }

    enum WebServerError: Error, LocalizedError {
        case noAvailablePort

        var errorDescription: String? {
            switch self {
            case .noAvailablePort:
                return "No available port found (tried \(WebServer.shared.basePort)-\(WebServer.shared.basePort + UInt16(WebServer.shared.maxPortAttempts) - 1))"
            }
        }
    }

}
