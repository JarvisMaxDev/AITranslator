import Foundation

/// Lightweight localhost HTTP server to capture OAuth callback.
/// Starts on a random available port, waits for a single GET request to /callback,
/// extracts the authorization code, and returns a success page to the browser.
final class LocalCallbackServer {
    private var listener: URLSessionStreamTask?
    private var serverSocket: Int32 = -1
    private var port: UInt16 = 0

    struct CallbackResult {
        let code: String?
        let state: String?
        let error: String?
    }

    /// Start listening on a specific or random available port
    func start(preferredPort: UInt16 = 0) async throws -> UInt16 {
        serverSocket = socket(AF_INET, SOCK_STREAM, 0)
        guard serverSocket >= 0 else {
            throw OAuthError.serverStartFailed("Failed to create socket")
        }

        // Allow address reuse
        var reuse: Int32 = 1
        setsockopt(serverSocket, SOL_SOCKET, SO_REUSEADDR, &reuse, socklen_t(MemoryLayout<Int32>.size))

        // Bind to any available port (port 0 = OS picks a free port)
        var addr = sockaddr_in()
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_port = preferredPort.bigEndian // 0 = OS assigns port
        addr.sin_addr.s_addr = inet_addr("127.0.0.1")

        let bindResult = withUnsafePointer(to: &addr) { ptr in
            ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sockPtr in
                bind(serverSocket, sockPtr, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        guard bindResult == 0 else {
            close(serverSocket)
            throw OAuthError.serverStartFailed("Failed to bind socket")
        }

        // Get the assigned port
        var assignedAddr = sockaddr_in()
        var addrLen = socklen_t(MemoryLayout<sockaddr_in>.size)
        withUnsafeMutablePointer(to: &assignedAddr) { ptr in
            ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sockPtr in
                getsockname(serverSocket, sockPtr, &addrLen)
            }
        }
        port = assignedAddr.sin_port.bigEndian

        // Start listening
        guard listen(serverSocket, 1) == 0 else {
            close(serverSocket)
            throw OAuthError.serverStartFailed("Failed to listen on socket")
        }

        return port
    }

    /// Wait for a single callback request and extract the authorization code
    func waitForCallback(timeoutSeconds: Int) async throws -> CallbackResult {
        return try await withCheckedThrowingContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async { [self] in
                // Set timeout on accept
                var timeout = timeval(tv_sec: timeoutSeconds, tv_usec: 0)
                setsockopt(serverSocket, SOL_SOCKET, SO_RCVTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))

                // Accept one connection
                var clientAddr = sockaddr_in()
                var clientAddrLen = socklen_t(MemoryLayout<sockaddr_in>.size)
                let clientSocket = withUnsafeMutablePointer(to: &clientAddr) { ptr in
                    ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sockPtr in
                        accept(serverSocket, sockPtr, &clientAddrLen)
                    }
                }

                guard clientSocket >= 0 else {
                    continuation.resume(throwing: OAuthError.timeout)
                    return
                }

                // Read the HTTP request
                var buffer = [UInt8](repeating: 0, count: 4096)
                let bytesRead = recv(clientSocket, &buffer, buffer.count, 0)

                guard bytesRead > 0 else {
                    close(clientSocket)
                    continuation.resume(throwing: OAuthError.noDataReceived)
                    return
                }

                let requestString = String(bytes: buffer[0..<bytesRead], encoding: .utf8) ?? ""

                // Parse the GET request line: "GET /callback?code=...&state=... HTTP/1.1"
                let result = self.parseCallbackRequest(requestString)

                // Send response back to browser
                let successHTML = """
                    <html>
                    <head><title>Authorization Complete</title></head>
                    <body style="font-family:-apple-system,system-ui;display:flex;align-items:center;justify-content:center;height:100vh;margin:0;background:#1a1a1a;color:#fff">
                    <div style="text-align:center">
                    <h1>✅ Authorization Successful</h1>
                    <p>You can close this tab and return to AI Translator.</p>
                    <script>setTimeout(()=>window.close(),2000)</script>
                    </div>
                    </body>
                    </html>
                    """
                let response = "HTTP/1.1 200 OK\r\nContent-Type: text/html\r\nConnection: close\r\n\r\n\(successHTML)"
                _ = response.withCString { ptr in
                    send(clientSocket, ptr, strlen(ptr), 0)
                }

                close(clientSocket)
                continuation.resume(returning: result)
            }
        }
    }

    /// Stop the server
    func stop() {
        if serverSocket >= 0 {
            close(serverSocket)
            serverSocket = -1
        }
    }

    deinit {
        stop()
    }

    // MARK: - Private

    private func parseCallbackRequest(_ request: String) -> CallbackResult {
        // Extract the path from "GET /callback?... HTTP/1.1"
        guard let firstLine = request.components(separatedBy: "\r\n").first,
              let pathPart = firstLine.components(separatedBy: " ").dropFirst().first,
              let urlComponents = URLComponents(string: "http://localhost\(pathPart)") else {
            return CallbackResult(code: nil, state: nil, error: "Invalid request")
        }

        let queryItems = urlComponents.queryItems ?? []
        let code = queryItems.first(where: { $0.name == "code" })?.value
        let state = queryItems.first(where: { $0.name == "state" })?.value
        let error = queryItems.first(where: { $0.name == "error" })?.value

        return CallbackResult(code: code, state: state, error: error)
    }
}
