import Foundation

enum RPCError: LocalizedError {
    case disconnected
    case invalidResponse
    case serverError(String)
    case timedOut
    case unsupportedMessage

    var errorDescription: String? {
        switch self {
        case .disconnected:
            "Disconnected from Codex app-server."
        case .invalidResponse:
            "Codex app-server returned an unexpected response."
        case .serverError(let message):
            message
        case .timedOut:
            "Codex app-server did not respond in time."
        case .unsupportedMessage:
            "Codex app-server returned an unsupported message type."
        }
    }
}

enum RPCNotification {
    case accountUpdated
    case rateLimitsUpdated(RateLimitSnapshot?)
}

final class CodexRPCClient: @unchecked Sendable {
    private let endpoint: URL
    private var socket: URLSessionWebSocketTask?
    private var nextID = 1
    private var pending: [Int: CheckedContinuation<[String: Any]?, Error>] = [:]
    private let requestTimeoutSeconds: TimeInterval = 10

    var onNotification: ((RPCNotification) -> Void)?
    var onDisconnect: ((Error) -> Void)?

    init(endpoint: URL) {
        self.endpoint = endpoint
    }

    func connect() async throws {
        disconnect(clearCallbacks: false)
        let socket = URLSession.shared.webSocketTask(with: endpoint)
        self.socket = socket
        socket.resume()
        receiveNext(for: socket)
        _ = try await request(
            method: "initialize",
            params: [
                "clientInfo": [
                    "name": "codex-account-tracker",
                    "title": "Codex Account Tracker",
                    "version": "0.1.0"
                ],
                "capabilities": [
                    "experimentalApi": true
                ]
            ]
        )
    }

    func disconnect(clearCallbacks: Bool = true) {
        socket?.cancel(with: .goingAway, reason: nil)
        socket = nil
        failAll(with: RPCError.disconnected)
        if clearCallbacks {
            onNotification = nil
            onDisconnect = nil
        }
    }

    func readAccount(refreshToken: Bool = false) async throws -> (email: String, planType: String)? {
        let result = try await request(
            method: "account/read",
            params: ["refreshToken": refreshToken]
        )

        guard let result else { return nil }
        guard let account = result["account"] as? [String: Any] else { return nil }
        guard account["type"] as? String == "chatgpt" else { return nil }
        guard let email = account["email"] as? String else { return nil }

        return (
            email: email,
            planType: account["planType"] as? String ?? "unknown"
        )
    }

    func readRateLimits() async throws -> RateLimitSnapshot? {
        let result = try await request(method: "account/rateLimits/read", params: nil)
        return Self.parseRateLimitSnapshot(from: result)
    }

    private func request(method: String, params: [String: Any]?) async throws -> [String: Any]? {
        guard let socket else { throw RPCError.disconnected }
        let id = nextID
        nextID += 1

        var envelope: [String: Any] = [
            "id": id,
            "method": method
        ]
        if let params {
            envelope["params"] = params
        }

        let data = try JSONSerialization.data(withJSONObject: envelope)
        let text = String(decoding: data, as: UTF8.self)

        return try await withCheckedThrowingContinuation { continuation in
            pending[id] = continuation
            DispatchQueue.main.asyncAfter(deadline: .now() + requestTimeoutSeconds) { [weak self] in
                guard let self else { return }
                guard let continuation = self.pending.removeValue(forKey: id) else { return }
                continuation.resume(throwing: RPCError.timedOut)
                self.handleDisconnect(RPCError.timedOut)
            }
            socket.send(.string(text)) { [weak self] error in
                if let error {
                    DispatchQueue.main.async {
                        guard let self else { return }
                        self.pending.removeValue(forKey: id)?.resume(throwing: error)
                    }
                }
            }
        }
    }

    private func receiveNext(for currentSocket: URLSessionWebSocketTask) {
        currentSocket.receive { [weak self] result in
            guard let self else { return }

            switch result {
            case .success(let message):
                DispatchQueue.main.async {
                    guard self.socket === currentSocket else { return }
                    self.handle(message: message)
                    if self.socket === currentSocket {
                        self.receiveNext(for: currentSocket)
                    }
                }
            case .failure(let error):
                DispatchQueue.main.async {
                    guard self.socket === currentSocket else { return }
                    self.handleDisconnect(error)
                }
            }
        }
    }

    private func handleDisconnect(_ error: Error) {
        let currentSocket = socket
        socket = nil
        currentSocket?.cancel(with: .goingAway, reason: nil)
        failAll(with: error)
        let callback = onDisconnect
        onNotification = nil
        onDisconnect = nil
        callback?(error)
    }

    private func handle(message: URLSessionWebSocketTask.Message) {
        let data: Data

        switch message {
        case .string(let text):
            data = Data(text.utf8)
        case .data(let value):
            data = value
        @unknown default:
            failAll(with: RPCError.unsupportedMessage)
            return
        }

        guard
            let json = try? JSONSerialization.jsonObject(with: data),
            let object = json as? [String: Any]
        else {
            failAll(with: RPCError.invalidResponse)
            return
        }

        if let id = object["id"] as? Int {
            handleResponse(object, id: id)
            return
        }

        if let method = object["method"] as? String {
            handleNotification(method: method, params: object["params"] as? [String: Any])
        }
    }

    private func handleResponse(_ object: [String: Any], id: Int) {
        guard let continuation = pending.removeValue(forKey: id) else { return }

        if let error = object["error"] as? [String: Any] {
            let message = error["message"] as? String ?? "Codex app-server returned an error."
            continuation.resume(throwing: RPCError.serverError(message))
            return
        }

        continuation.resume(returning: object["result"] as? [String: Any])
    }

    private func handleNotification(method: String, params: [String: Any]?) {
        switch method {
        case "account/updated":
            onNotification?(.accountUpdated)
        case "account/rateLimits/updated":
            onNotification?(.rateLimitsUpdated(Self.parseRateLimitSnapshot(from: params)))
        default:
            break
        }
    }

    private func failAll(with error: Error) {
        for (_, continuation) in pending {
            continuation.resume(throwing: error)
        }
        pending.removeAll()
    }

    static func parseRateLimitSnapshot(from value: Any?) -> RateLimitSnapshot? {
        guard let object = value as? [String: Any] else { return nil }

        if let snapshot = parseDirectRateLimitSnapshot(object), snapshot.hasQuotaData {
            return snapshot
        }

        if let rateLimits = object["rateLimits"] as? [String: Any] {
            if let snapshot = parseDirectRateLimitSnapshot(rateLimits), snapshot.hasQuotaData {
                return snapshot
            }

            if let byLimitID = rateLimits["rateLimitsByLimitId"] as? [String: Any],
               let codex = byLimitID["codex"] as? [String: Any],
               let snapshot = parseDirectRateLimitSnapshot(codex),
               snapshot.hasQuotaData {
                return snapshot
            }
        }

        if let byLimitID = object["rateLimitsByLimitId"] as? [String: Any],
           let codex = byLimitID["codex"] as? [String: Any],
           let snapshot = parseDirectRateLimitSnapshot(codex),
           snapshot.hasQuotaData {
            return snapshot
        }

        return nil
    }

    private static func parseDirectRateLimitSnapshot(_ object: [String: Any]) -> RateLimitSnapshot? {
        let snapshot = RateLimitSnapshot(
            planType: object["planType"] as? String,
            primary: parseWindow(object["primary"]),
            secondary: parseWindow(object["secondary"])
        )

        return snapshot.hasQuotaData || snapshot.planType != nil ? snapshot : nil
    }

    private static func parseWindow(_ value: Any?) -> RateLimitWindow? {
        guard let object = value as? [String: Any],
              let usedPercent = intValue(object["usedPercent"])
        else {
            return nil
        }

        return RateLimitWindow(
            usedPercent: usedPercent,
            windowDurationMins: intValue(object["windowDurationMins"]),
            resetsAt: int64Value(object["resetsAt"])
        )
    }

    private static func intValue(_ value: Any?) -> Int? {
        if let value = value as? Int { return value }
        if let value = value as? Int64 { return Int(value) }
        if let value = value as? Double { return Int(value) }
        if let value = value as? NSNumber { return value.intValue }
        return nil
    }

    private static func int64Value(_ value: Any?) -> Int64? {
        if let value = value as? Int64 { return value }
        if let value = value as? Int { return Int64(value) }
        if let value = value as? Double { return Int64(value) }
        if let value = value as? NSNumber { return value.int64Value }
        return nil
    }

}
