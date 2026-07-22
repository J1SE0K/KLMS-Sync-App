import Foundation

private final class ServerRelayNoRedirectDelegate: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
    func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        willPerformHTTPRedirection response: HTTPURLResponse,
        newRequest request: URLRequest,
        completionHandler: @escaping (URLRequest?) -> Void
    ) {
        completionHandler(nil)
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
        for component in ["v1", "file-access", requestID.uuidString, "download"] {
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
        let redirectDelegate = ServerRelayNoRedirectDelegate()
        let session = URLSession(
            configuration: configuration,
            delegate: redirectDelegate,
            delegateQueue: nil
        )
        defer { session.invalidateAndCancel() }

        var request = URLRequest(url: downloadURL)
        request.timeoutInterval = 12 * 60
        request.httpMethod = "GET"
        request.setValue("Bearer \(capability)", forHTTPHeaderField: "Authorization")
        request.setValue("application/octet-stream", forHTTPHeaderField: "Accept")
        request.setValue(Self.downloadClientSourceName, forHTTPHeaderField: "X-KLMS-Client")
        let (temporaryURL, response) = try await session.download(for: request)
        defer { try? FileManager.default.removeItem(at: temporaryURL) }
        guard let httpResponse = response as? HTTPURLResponse,
              (200..<300).contains(httpResponse.statusCode),
              let responseURL = httpResponse.url,
              ServerRelayFileDownloadPolicy.isExactURL(
                  responseURL,
                  baseURL: baseURL,
                  requestID: fileRequest.id
              ) else {
            throw ServerRelayClientError.invalidResponse
        }
        let attributes = try FileManager.default.attributesOfItem(atPath: temporaryURL.path)
        let actualBytes = (attributes[.size] as? NSNumber)?.intValue ?? -1
        guard actualBytes >= 0,
              actualBytes <= ServerRelayFileDownloadPolicy.maximumBytes else {
            throw ServerRelayClientError.invalidResponse
        }

        let filename = ServerRelayFileDownloadPolicy.safeFilename(
            httpResponse.suggestedFilename ?? fileRequest.itemTitle
        )
        let destinationDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("KLMS Sync File Access", isDirectory: true)
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(
            at: destinationDirectory,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
        let destinationURL = destinationDirectory.appendingPathComponent(filename, isDirectory: false)
        try FileManager.default.moveItem(at: temporaryURL, to: destinationURL)
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
