import Foundation
import Network

/// `Freshflo --mcp-http [--port 8765] [--bind 127.0.0.1]`: the same MCP server over Streamable HTTP, for agents that
/// can't start a process on this Mac, such as Hermes in an NVIDIA NemoClaw / OpenShell sandbox (it reaches Freshflo
/// through an HTTPS reverse proxy). Answers with plain JSON; no server-sent stream, no sessions.
/// Requests must carry `Authorization: Bearer $FRESHFLO_MCP_TOKEN`; without a token it only listens on loopback.
enum MCPHTTP {
    static let maxBytes = 1_000_000

    struct Request: Equatable {
        let method: String
        let path: String
        let headers: [String: String]
        let body: Data
    }

    enum Parsed: Equatable {
        case incomplete, bad
        case request(Request)
    }

    struct Response: Equatable {
        let status: Int
        var headers: [String: String] = [:]
        var body = Data()
    }

    // MARK: Parsing

    static func parse(_ data: Data) -> Parsed {
        guard data.count <= maxBytes else { return .bad }
        guard let end = data.range(of: Data("\r\n\r\n".utf8)) else { return .incomplete }
        guard let head = String(data: data[..<end.lowerBound], encoding: .utf8) else { return .bad }
        let lines = head.components(separatedBy: "\r\n")
        let first = lines[0].split(separator: " ")
        guard first.count == 3, first[2].hasPrefix("HTTP/1.") else { return .bad }
        var headers: [String: String] = [:]
        for line in lines.dropFirst() {
            guard let colon = line.firstIndex(of: ":") else { return .bad }
            headers[line[..<colon].trimmingCharacters(in: .whitespaces).lowercased()] = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
        }
        if headers["transfer-encoding"] != nil { return .bad } // chunked bodies aren't needed by MCP clients
        let length = Int(headers["content-length"] ?? "0") ?? -1
        guard length >= 0 else { return .bad }
        let bodyStart = end.upperBound
        guard data.count - bodyStart >= length else { return .incomplete }
        let path = String(first[1].split(separator: "?", maxSplits: 1).first ?? "")
        return .request(Request(method: String(first[0]).uppercased(), path: path, headers: headers,
                                body: Data(data[bodyStart..<(bodyStart + length)])))
    }

    // MARK: Answering

    static func respond(to request: Request, token: String) -> Response {
        guard request.path == "/mcp" else { return text(404, "Not found. The MCP endpoint is /mcp.") }
        // A web page must not be able to drive this server through the user's browser (DNS rebinding).
        if let origin = request.headers["origin"], !isLocal(origin: origin) { return text(403, "Origin not allowed.") }
        if !token.isEmpty {
            let given = request.headers["authorization"] ?? ""
            guard given.hasPrefix("Bearer "), sameSecret(String(given.dropFirst(7)), token) else {
                var r = text(401, "Missing or wrong bearer token.")
                r.headers["WWW-Authenticate"] = "Bearer"
                return r
            }
        }
        guard request.method == "POST" else {
            var r = text(405, "Use POST. This server sends no event stream.")
            r.headers["Allow"] = "POST"
            return r
        }
        guard let parsed = try? JSONSerialization.jsonObject(with: request.body) else {
            return json(400, ["jsonrpc": "2.0", "id": NSNull(), "error": ["code": -32700, "message": "Parse error"]])
        }
        if let batch = parsed as? [[String: Any]] {
            let replies = batch.compactMap(MCPServer.reply(to:))
            return replies.isEmpty ? Response(status: 202) : json(200, replies)
        }
        guard let message = parsed as? [String: Any] else {
            return json(400, ["jsonrpc": "2.0", "id": NSNull(), "error": ["code": -32600, "message": "Invalid request"]])
        }
        // Notifications and responses from the client are accepted without a body.
        guard let reply = MCPServer.reply(to: message) else { return Response(status: 202) }
        return json(200, reply)
    }

    static func isLocal(origin: String) -> Bool {
        guard let host = URL(string: origin)?.host?.lowercased() else { return false }
        return host == "localhost" || host == "127.0.0.1" || host == "::1" || host == "[::1]"
    }

    /// Compares without stopping at the first difference, so timing doesn't reveal how much of a guess was right.
    static func sameSecret(_ a: String, _ b: String) -> Bool {
        let x = Array(a.utf8), y = Array(b.utf8)
        guard x.count == y.count else { return false }
        var diff: UInt8 = 0
        for i in x.indices { diff |= x[i] ^ y[i] }
        return diff == 0
    }

    private static func text(_ status: Int, _ message: String) -> Response {
        Response(status: status, headers: ["Content-Type": "text/plain; charset=utf-8"], body: Data(message.utf8))
    }

    private static func json(_ status: Int, _ object: Any) -> Response {
        Response(status: status, headers: ["Content-Type": "application/json"],
                 body: (try? JSONSerialization.data(withJSONObject: object)) ?? Data())
    }

    static func serialize(_ response: Response) -> Data {
        let reasons = [200: "OK", 202: "Accepted", 400: "Bad Request", 401: "Unauthorized", 403: "Forbidden", 404: "Not Found", 405: "Method Not Allowed"]
        var head = "HTTP/1.1 \(response.status) \(reasons[response.status] ?? "Error")\r\n"
        var headers = response.headers
        headers["Content-Length"] = String(response.body.count)
        headers["Connection"] = "close"
        for (name, value) in headers.sorted(by: { $0.key < $1.key }) { head += "\(name): \(value)\r\n" }
        return Data((head + "\r\n").utf8) + response.body
    }

    // MARK: Serving

    static func isLoopback(_ host: String) -> Bool {
        host == "127.0.0.1" || host == "::1" || host == "localhost"
    }

    static func run(port: UInt16, bind host: String, token: String) -> Never {
        guard !token.isEmpty || isLoopback(host) else {
            print("error: set FRESHFLO_MCP_TOKEN before listening on \(host); without a token Freshflo only serves loopback.")
            exit(1)
        }
        guard let nwPort = NWEndpoint.Port(rawValue: port) else { print("error: bad port \(port)"); exit(1) }
        let parameters = NWParameters.tcp
        parameters.requiredLocalEndpoint = .hostPort(host: NWEndpoint.Host(host), port: nwPort)
        parameters.allowLocalEndpointReuse = true
        let listener: NWListener
        do { listener = try NWListener(using: parameters) } catch { print("error: \(error.localizedDescription)"); exit(1) }
        listener.newConnectionHandler = { connection in MCPHTTPConnection(connection, token: token).start() }
        listener.stateUpdateHandler = { state in
            switch state {
            case .ready:
                print("Freshflo MCP over HTTP on http://\(host):\(port)/mcp · bearer token \(token.isEmpty ? "off (loopback only)" : "required")")
            case .failed(let error):
                print("error: \(error.localizedDescription)")
                exit(1)
            default: break
            }
        }
        listener.start(queue: .main)
        dispatchMain()
    }
}

/// One request per connection: read until the body is complete, answer, close.
private final class MCPHTTPConnection {
    private let connection: NWConnection
    private let token: String
    private var buffer = Data()

    init(_ connection: NWConnection, token: String) {
        self.connection = connection
        self.token = token
    }

    func start() {
        connection.start(queue: .main)
        receive()
    }

    private func receive() {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 65_536) { [self] data, _, finished, error in
            if let data { buffer.append(data) }
            switch MCPHTTP.parse(buffer) {
            case .request(let request):
                reply(MCPHTTP.respond(to: request, token: token))
            case .incomplete where !finished && error == nil:
                receive()
            case .incomplete, .bad:
                reply(MCPHTTP.Response(status: 400, headers: ["Content-Type": "text/plain"], body: Data("Bad request".utf8)))
            }
        }
    }

    private func reply(_ response: MCPHTTP.Response) {
        connection.send(content: MCPHTTP.serialize(response), completion: .contentProcessed { [self] _ in connection.cancel() })
    }
}
