import Foundation
import OpenBoardKit

/**
 The network half of `T3Code`: find T3's server, read its threads, answer a prompt.

 An actor so the fetch and the decode never run on the main actor — the snapshot carries
 every thread, and a slow T3 must not be able to stall painting the pad or a key press.
 What the threads *mean* is decided in `T3Code.State`, which the controller owns.

 Polled over HTTP rather than streamed: T3's stream is Effect-RPC and wants an ack after
 every chunk. A poll every second and a half is one small request and nothing to keep
 alive.
 */
actor T3Client {
    enum Poll: Sendable {
        case snapshot(T3Code.ShellSnapshot)
        /// Why there is no snapshot. For a server that is down — not running, not
        /// answering, or answering with something that does not decode — the reason is
        /// kept for the log.
        case unavailable(T3Code.Status, reason: String? = nil)
        /// The server is there but did not answer in time: busy, typically starting a
        /// thread. Unlike down, worth asking again at the usual pace.
        case timedOut
    }

    private let session: URLSession
    /// The server whose protocol has been checked. A new pid is a relaunched or updated
    /// T3, and an update is exactly when the protocol could have moved.
    private var checkedPID: Int?

    init() {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 2
        configuration.urlCache = nil
        session = URLSession(configuration: configuration)
    }

    func poll() async -> Poll {
        guard let token = T3Code.readToken() else { return .unavailable(.noToken) }
        guard let runtime = T3Code.readRuntime() else {
            checkedPID = nil
            return .unavailable(.serverDown, reason: "no runtime file")
        }
        // A crash leaves the runtime file behind.
        guard SessionRegistry.processIsAlive(runtime.pid) else {
            checkedPID = nil
            return .unavailable(.serverDown, reason: "server pid \(runtime.pid) is gone")
        }
        guard let origin = URL(string: runtime.origin) else {
            return .unavailable(.serverDown, reason: "unreadable origin \(runtime.origin)")
        }

        if checkedPID != runtime.pid {
            do {
                let (data, _) = try await session.data(
                    from: origin.appending(path: ".well-known/t3/environment")
                )
                let version = try JSONDecoder().decode(T3Code.Environment.self, from: data)
                    .orchestrationProtocolVersion
                guard version == T3Code.protocolVersion else {
                    return .unavailable(.protocolMismatch(version))
                }
                checkedPID = runtime.pid
            } catch {
                return .unavailable(.serverDown, reason: "environment check failed: \(error.localizedDescription)")
            }
        }

        var request = URLRequest(url: origin.appending(path: "api/orchestration/shell"))
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue(String(T3Code.protocolVersion), forHTTPHeaderField: "x-t3-orchestration-protocol")
        do {
            let (data, response) = try await session.data(for: request)
            let status = (response as? HTTPURLResponse)?.statusCode ?? 0
            if status == 401 || status == 403 { return .unavailable(.tokenRejected) }
            guard status == 200 else {
                return .unavailable(.serverDown, reason: "shell answered HTTP \(status)")
            }
            return .snapshot(try JSONDecoder().decode(T3Code.ShellSnapshot.self, from: data))
        } catch let error as DecodingError {
            return .unavailable(.serverDown, reason: "shell did not decode: \(String("\(error)".prefix(200)))")
        } catch let error as URLError where error.code == .timedOut {
            return .timedOut
        } catch {
            return .unavailable(.serverDown, reason: "shell request failed: \(error.localizedDescription)")
        }
    }

    /**
     Answer one pending request: a single RPC over T3's WebSocket, then close.

     Five seconds, then give up — the key press that asked is waiting on nothing else.
     */
    func respond(threadID: String, requestID: String, decision: String) async -> T3Code.RespondResult {
        guard let token = T3Code.readToken() else { return .failed("no token") }
        guard let runtime = T3Code.readRuntime(), SessionRegistry.processIsAlive(runtime.pid) else {
            return .failed("T3 Code is not running")
        }
        var components = URLComponents()
        components.scheme = "ws"
        components.host = runtime.host
        components.port = runtime.port
        components.path = "/ws"
        // Without it the server answers 426 rather than upgrading.
        components.queryItems = [
            URLQueryItem(name: "orchestrationProtocol", value: String(T3Code.protocolVersion)),
        ]
        guard let url = components.url else { return .failed("unreadable server address") }

        var request = URLRequest(url: url)
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        let task = session.webSocketTask(with: request)
        let started = Date()
        task.resume()
        // `receive` has no timeout of its own; cancelling the task is what ends it.
        let timeout = Task {
            try? await Task.sleep(for: .seconds(5))
            task.cancel(with: .goingAway, reason: nil)
        }
        defer {
            timeout.cancel()
            task.cancel(with: .normalClosure, reason: nil)
        }

        let frame = T3Code.respondRequest(
            threadID: threadID,
            requestID: requestID,
            decision: decision,
            commandID: "openboard:\(UUID().uuidString)"
        )
        do {
            try await task.send(.string(String(decoding: frame, as: UTF8.self)))
            while true {
                let data: Data
                switch try await task.receive() {
                case let .string(text): data = Data(text.utf8)
                case let .data(bytes): data = bytes
                @unknown default: continue
                }
                if let outcome = T3Code.exitOutcome(fromFrame: data) {
                    return outcome
                }
            }
        } catch {
            let timedOut = Date().timeIntervalSince(started) >= 5
            return .failed(timedOut ? "no answer within 5s" : error.localizedDescription)
        }
    }
}
