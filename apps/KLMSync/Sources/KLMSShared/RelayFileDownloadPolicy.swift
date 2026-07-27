import Foundation

public struct ServerRelayDownloadByteBudget: Equatable, Sendable {
    public let maximumBytes: Int64
    public private(set) var receivedBytes: Int64 = 0

    public init(maximumBytes: Int64) {
        self.maximumBytes = max(0, maximumBytes)
    }

    @discardableResult
    public mutating func consume(_ byteCount: Int) -> Bool {
        guard byteCount >= 0,
              receivedBytes <= maximumBytes,
              Int64(byteCount) <= maximumBytes - receivedBytes else {
            return false
        }
        receivedBytes += Int64(byteCount)
        return true
    }
}

private final class ServerRelayBoundedDownloadDelegate: NSObject, URLSessionDataDelegate, @unchecked Sendable {
    private let baseURL: URL
    private let requestID: UUID
    private let fileHandle: FileHandle
    private let lock = NSLock()
    private var byteBudget: ServerRelayDownloadByteBudget
    private var continuation: CheckedContinuation<HTTPURLResponse, Error>?
    private var session: URLSession?
    private var completed = false

    init(baseURL: URL, requestID: UUID, destinationURL: URL, maximumBytes: Int64) throws {
        self.baseURL = baseURL
        self.requestID = requestID
        byteBudget = ServerRelayDownloadByteBudget(maximumBytes: maximumBytes)
        guard FileManager.default.createFile(
            atPath: destinationURL.path,
            contents: nil,
            attributes: [.posixPermissions: 0o600]
        ) else {
            throw ServerRelayClientError.invalidResponse
        }
        fileHandle = try FileHandle(forWritingTo: destinationURL)
    }

    func download(_ request: URLRequest, configuration: URLSessionConfiguration) async throws -> HTTPURLResponse {
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                lock.lock()
                guard !completed else {
                    lock.unlock()
                    continuation.resume(throwing: CancellationError())
                    return
                }
                self.continuation = continuation
                let delegateQueue = OperationQueue()
                delegateQueue.maxConcurrentOperationCount = 1
                delegateQueue.qualityOfService = .utility
                let session = URLSession(
                    configuration: configuration,
                    delegate: self,
                    delegateQueue: delegateQueue
                )
                self.session = session
                let wasCancelled = Task.isCancelled
                lock.unlock()
                if wasCancelled {
                    finish(.failure(CancellationError()))
                } else {
                    session.dataTask(with: request).resume()
                }
            }
        } onCancel: {
            self.cancel()
        }
    }

    func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        willPerformHTTPRedirection response: HTTPURLResponse,
        newRequest request: URLRequest,
        completionHandler: @escaping (URLRequest?) -> Void
    ) {
        completionHandler(nil)
    }

    func urlSession(
        _ session: URLSession,
        dataTask: URLSessionDataTask,
        didReceive response: URLResponse,
        completionHandler: @escaping (URLSession.ResponseDisposition) -> Void
    ) {
        guard let httpResponse = response as? HTTPURLResponse,
              (200..<300).contains(httpResponse.statusCode),
              let responseURL = httpResponse.url,
              ServerRelayFileDownloadPolicy.isExactURL(
                  responseURL,
                  baseURL: baseURL,
                  requestID: requestID
              ),
              response.expectedContentLength < 0
                || response.expectedContentLength <= byteBudget.maximumBytes else {
            completionHandler(.cancel)
            finish(.failure(ServerRelayClientError.invalidResponse))
            return
        }
        completionHandler(.allow)
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        guard byteBudget.consume(data.count) else {
            dataTask.cancel()
            finish(.failure(ServerRelayClientError.invalidResponse))
            return
        }
        do {
            try fileHandle.write(contentsOf: data)
        } catch {
            dataTask.cancel()
            finish(.failure(error))
        }
    }

    func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        didCompleteWithError error: Error?
    ) {
        if let error {
            finish(.failure(error))
            return
        }
        guard let response = task.response as? HTTPURLResponse else {
            finish(.failure(ServerRelayClientError.invalidResponse))
            return
        }
        finish(.success(response))
    }

    private func finish(_ result: Result<HTTPURLResponse, Error>) {
        lock.lock()
        guard !completed else {
            lock.unlock()
            return
        }
        completed = true
        let continuation = self.continuation
        self.continuation = nil
        let session = self.session
        self.session = nil
        lock.unlock()

        let finalResult: Result<HTTPURLResponse, Error>
        do {
            try fileHandle.synchronize()
            try fileHandle.close()
            finalResult = result
        } catch {
            finalResult = .failure(error)
        }
        session?.invalidateAndCancel()
        continuation?.resume(with: finalResult)
    }

    private func cancel() {
        lock.lock()
        let session = self.session
        lock.unlock()
        session?.invalidateAndCancel()
    }
}

public enum ServerRelayFileDownloadPolicy {
    public static let maximumBytes = 25 * 1024 * 1024

    public static func isValidCapability(_ value: String) -> Bool {
        value.range(
            of: #"^(?:[A-Za-z0-9_-]{32}|[0-9a-fA-F]{64})$"#,
            options: .regularExpression
        ) != nil
    }

    public static func expectedURL(baseURL: URL, requestID: UUID) -> URL {
        var url = baseURL
        for component in ["v1", "file-access", requestID.uuidString.lowercased(), "download"] {
            url.appendPathComponent(component)
        }
        return url
    }

    public static func isExactURL(_ candidate: URL, baseURL: URL, requestID: UUID) -> Bool {
        let expected = expectedURL(baseURL: baseURL, requestID: requestID)
        guard let candidateComponents = URLComponents(url: candidate, resolvingAgainstBaseURL: false),
              let expectedComponents = URLComponents(url: expected, resolvingAgainstBaseURL: false) else {
            return false
        }
        return candidateComponents.scheme?.lowercased() == expectedComponents.scheme?.lowercased()
            && candidateComponents.host?.lowercased() == expectedComponents.host?.lowercased()
            && candidateComponents.port == expectedComponents.port
            && candidateComponents.path == expectedComponents.path
            && candidateComponents.user == nil
            && candidateComponents.password == nil
            && candidateComponents.query == nil
            && candidateComponents.fragment == nil
    }

    public static func safeFilename(_ value: String) -> String {
        let invalid = CharacterSet(charactersIn: "\\/:*?\"<>|")
            .union(.controlCharacters)
        let sanitized = value.components(separatedBy: invalid).joined(separator: "_")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return String((sanitized.isEmpty ? "KLMS file" : sanitized).prefix(180))
    }
}

public extension ServerRelayCommandStore {
    func downloadFileAccessRequest(_ fileRequest: ServerRelayFileAccessRequest) async throws -> URL {
        guard fileRequest.isDownloadAvailable,
              let capability = fileRequest.downloadCapability?.trimmingCharacters(in: .whitespacesAndNewlines),
              ServerRelayFileDownloadPolicy.isValidCapability(capability),
              let urlText = fileRequest.downloadURL,
              let downloadURL = URL(string: urlText),
              ServerRelayFileDownloadPolicy.isExactURL(
                downloadURL,
                baseURL: baseURL,
                requestID: fileRequest.id
              ) else {
            throw ServerRelayClientError.invalidResponse
        }
        if let sizeBytes = fileRequest.sizeBytes,
           sizeBytes < 0 || sizeBytes > ServerRelayFileDownloadPolicy.maximumBytes {
            throw ServerRelayClientError.invalidResponse
        }

        let configuration = URLSessionConfiguration.ephemeral
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        configuration.urlCache = nil
        configuration.httpShouldSetCookies = false
        configuration.timeoutIntervalForRequest = 60
        configuration.timeoutIntervalForResource = 12 * 60
        var request = URLRequest(url: downloadURL)
        request.timeoutInterval = 12 * 60
        request.httpMethod = "GET"
        request.setValue("Bearer \(capability)", forHTTPHeaderField: "Authorization")
        request.setValue("application/octet-stream", forHTTPHeaderField: "Accept")
        request.setValue(Self.downloadClientSourceName, forHTTPHeaderField: "X-KLMS-Client")
        let destinationDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("KLMS Sync File Access", isDirectory: true)
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(
            at: destinationDirectory,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
        let partialURL = destinationDirectory.appendingPathComponent(".download.partial", isDirectory: false)
        let boundedDownload = try ServerRelayBoundedDownloadDelegate(
            baseURL: baseURL,
            requestID: fileRequest.id,
            destinationURL: partialURL,
            maximumBytes: Int64(ServerRelayFileDownloadPolicy.maximumBytes)
        )
        let httpResponse: HTTPURLResponse
        do {
            httpResponse = try await boundedDownload.download(request, configuration: configuration)
        } catch {
            try? FileManager.default.removeItem(at: destinationDirectory)
            throw error
        }
        let filename = ServerRelayFileDownloadPolicy.safeFilename(
            httpResponse.suggestedFilename ?? fileRequest.itemTitle
        )
        let destinationURL = destinationDirectory.appendingPathComponent(filename, isDirectory: false)
        do {
            try FileManager.default.moveItem(at: partialURL, to: destinationURL)
        } catch {
            try? FileManager.default.removeItem(at: destinationDirectory)
            throw error
        }
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: destinationURL.path)
        return destinationURL
    }

    private static var downloadClientSourceName: String {
        #if os(iOS)
        "iPhone"
        #elseif os(macOS)
        "Mac"
        #else
        "Swift"
        #endif
    }
}
