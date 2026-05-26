import Foundation
import KLMSShared
import Network

final class LocalRemoteServer: @unchecked Sendable {
    typealias Handler = (LocalRemoteRequest) async -> LocalRemoteResponse

    private let port: UInt16
    private let handler: Handler
    private let queue = DispatchQueue(label: "KLMSLocalRemoteServer")
    private var listener: NWListener?

    init(port: UInt16, handler: @escaping Handler) {
        self.port = port
        self.handler = handler
    }

    func start() throws {
        stop()
        guard let nwPort = NWEndpoint.Port(rawValue: port) else {
            throw LocalRemoteServerError.invalidPort
        }
        let listener = try NWListener(using: .tcp, on: nwPort)
        listener.newConnectionHandler = { [self] connection in
            LocalRemoteServerConnection(
                connection: connection,
                queue: queue,
                handler: handler
            ).start()
        }
        listener.start(queue: queue)
        self.listener = listener
    }

    func stop() {
        listener?.cancel()
        listener = nil
    }

}

private final class LocalRemoteServerConnection: @unchecked Sendable {
    private let connection: NWConnection
    private let queue: DispatchQueue
    private let handler: LocalRemoteServer.Handler
    private var buffer = Data()

    init(
        connection: NWConnection,
        queue: DispatchQueue,
        handler: @escaping LocalRemoteServer.Handler
    ) {
        self.connection = connection
        self.queue = queue
        self.handler = handler
    }

    func start() {
        connection.stateUpdateHandler = { [self] state in
            switch state {
            case .ready:
                receive()
            case .failed, .cancelled:
                connection.cancel()
            default:
                break
            }
        }
        connection.start(queue: queue)
    }

    private func receive() {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 64 * 1024) { [self] data, _, isComplete, error in
            if let error {
                send(LocalRemoteResponse(ok: false, message: error.localizedDescription))
                return
            }
            if let data {
                buffer.append(data)
                if let newlineIndex = buffer.firstIndex(of: 0x0A) {
                    let requestData = Data(buffer[..<newlineIndex])
                    Task { [self] in
                        send(await decodeAndHandle(requestData))
                    }
                    return
                }
            }
            if isComplete {
                let requestData = buffer
                Task { [self] in
                    send(await decodeAndHandle(requestData))
                }
            } else {
                receive()
            }
        }
    }

    private func send(_ response: LocalRemoteResponse) {
        let payload: Data
        do {
            payload = try JSONEncoder.klmsLocalRemote.encode(response) + Data([0x0A])
        } catch {
            payload = Data()
        }
        connection.send(content: payload, completion: .contentProcessed { [self] _ in
            connection.cancel()
        })
    }

    private func decodeAndHandle(_ data: Data) async -> LocalRemoteResponse {
        do {
            let request = try JSONDecoder.klmsLocalRemote.decode(LocalRemoteRequest.self, from: data)
            return await handler(request)
        } catch {
            return LocalRemoteResponse(ok: false, message: "요청을 해석하지 못했습니다.")
        }
    }
}

enum LocalRemoteServerError: LocalizedError {
    case invalidPort

    var errorDescription: String? {
        switch self {
        case .invalidPort:
            "로컬 원격 제어 포트가 올바르지 않습니다."
        }
    }
}
