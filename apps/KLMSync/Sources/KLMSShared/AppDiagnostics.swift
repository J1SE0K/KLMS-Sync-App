import Foundation

public struct KLMSAppDiagnostics: Sendable, Equatable {
    public var bundlePath: String
    public var bundleIdentifier: String
    public var payloadVersion: String
    public var installedPayloadVersion: String
    public var engineRoot: String
    public var codeSigning: KLMSCodeSigningInfo

    public init(
        bundlePath: String = "",
        bundleIdentifier: String = "",
        payloadVersion: String = "",
        installedPayloadVersion: String = "",
        engineRoot: String = "",
        codeSigning: KLMSCodeSigningInfo = KLMSCodeSigningInfo()
    ) {
        self.bundlePath = bundlePath
        self.bundleIdentifier = bundleIdentifier
        self.payloadVersion = payloadVersion
        self.installedPayloadVersion = installedPayloadVersion
        self.engineRoot = engineRoot
        self.codeSigning = codeSigning
    }

    public static func collect(
        bundleURL: URL,
        bundleIdentifier: String?,
        paths: KLMSPaths,
        payloadVersion: String?,
        fileManager: FileManager = .default
    ) -> KLMSAppDiagnostics {
        let installedVersion = (try? String(contentsOf: paths.installedPayloadVersionURL, encoding: .utf8)
            .trimmingCharacters(in: .whitespacesAndNewlines)) ?? ""
        return KLMSAppDiagnostics(
            bundlePath: bundleURL.path,
            bundleIdentifier: bundleIdentifier ?? "",
            payloadVersion: payloadVersion ?? "",
            installedPayloadVersion: installedVersion,
            engineRoot: paths.engineRoot.path,
            codeSigning: KLMSCodeSigningInfo.collect(bundleURL: bundleURL)
        )
    }
}

public struct KLMSCodeSigningInfo: Sendable, Equatable {
    public var signature: String
    public var teamIdentifier: String
    public var cdHash: String
    public var verificationSucceeded: Bool?
    public var verificationOutput: String
    public var validIdentityCount: Int?
    public var entitlementsOutput: String
    public var cloudKitEntitled: Bool
    public var rawOutput: String

    public init(
        signature: String = "",
        teamIdentifier: String = "",
        cdHash: String = "",
        verificationSucceeded: Bool? = nil,
        verificationOutput: String = "",
        validIdentityCount: Int? = nil,
        entitlementsOutput: String = "",
        cloudKitEntitled: Bool = false,
        rawOutput: String = ""
    ) {
        self.signature = signature
        self.teamIdentifier = teamIdentifier
        self.cdHash = cdHash
        self.verificationSucceeded = verificationSucceeded
        self.verificationOutput = verificationOutput
        self.validIdentityCount = validIdentityCount
        self.entitlementsOutput = entitlementsOutput
        self.cloudKitEntitled = cloudKitEntitled
        self.rawOutput = rawOutput
    }

    public var isAdHoc: Bool {
        signature.localizedCaseInsensitiveContains("adhoc")
            || teamIdentifier.localizedCaseInsensitiveContains("not set")
    }

    public var needsAttention: Bool {
        isAdHoc || verificationSucceeded == false || (validIdentityCount ?? 1) == 0
    }

    public var statusTitle: String {
        if verificationSucceeded == false {
            return "서명 검증 실패"
        }
        if isAdHoc {
            return "임시 서명"
        }
        if !signature.isEmpty || !teamIdentifier.isEmpty {
            return "고정 서명"
        }
        return "서명 정보 없음"
    }

    public var statusDetail: String {
        if verificationSucceeded == false {
            let detail = Self.firstNonEmptyLine(in: verificationOutput)
            if !detail.isEmpty {
                return detail
            }
            return "codesign --verify 검증에 실패했습니다. macOS 권한이 재빌드 후 흔들릴 수 있습니다."
        }
        if isAdHoc {
            return "앱을 다시 빌드하면 macOS 자동화/손쉬운 사용 권한이 다시 흔들릴 수 있습니다."
        }
        if !teamIdentifier.isEmpty {
            return "TeamIdentifier \(teamIdentifier)"
        }
        return "codesign 정보를 읽지 못했습니다."
    }

    static func collect(bundleURL: URL) -> KLMSCodeSigningInfo {
        let codeSignOutput = runProcess(
            executable: "/usr/bin/codesign",
            arguments: ["-dv", "--verbose=4", bundleURL.path]
        )
        let verification = runProcessResult(
            executable: "/usr/bin/codesign",
            arguments: ["--verify", "--deep", "--strict", "--verbose=4", bundleURL.path]
        )
        let entitlementsOutput = runProcess(
            executable: "/usr/bin/codesign",
            arguments: ["-d", "--entitlements", ":-", bundleURL.path]
        )
        let identityOutput = runProcess(
            executable: "/usr/bin/security",
            arguments: ["find-identity", "-v", "-p", "codesigning"]
        )
        return KLMSCodeSigningInfo(
            signature: value(after: "Signature=", in: codeSignOutput),
            teamIdentifier: value(after: "TeamIdentifier=", in: codeSignOutput),
            cdHash: value(after: "CDHash=", in: codeSignOutput),
            verificationSucceeded: verification.status == 0,
            verificationOutput: verification.output,
            validIdentityCount: validIdentityCount(from: identityOutput),
            entitlementsOutput: entitlementsOutput,
            cloudKitEntitled: entitlementsOutput.contains("com.apple.developer.icloud-services")
                && entitlementsOutput.contains("CloudKit"),
            rawOutput: codeSignOutput
        )
    }

    private static func runProcess(executable: String, arguments: [String]) -> String {
        runProcessResult(executable: executable, arguments: arguments).output
    }

    private static func runProcessResult(executable: String, arguments: [String]) -> (status: Int32, output: String) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        let output = Pipe()
        process.standardOutput = output
        process.standardError = output
        do {
            try process.run()
            process.waitUntilExit()
        } catch {
            return (-1, "")
        }
        let data = output.fileHandleForReading.readDataToEndOfFile()
        return (process.terminationStatus, String(data: data, encoding: .utf8) ?? "")
    }

    private static func value(after prefix: String, in text: String) -> String {
        text
            .split(whereSeparator: \.isNewline)
            .compactMap { line -> String? in
                guard let range = line.range(of: prefix) else {
                    return nil
                }
                return String(line[range.upperBound...]).trimmingCharacters(in: .whitespacesAndNewlines)
            }
            .first ?? ""
    }

    private static func validIdentityCount(from text: String) -> Int? {
        let pattern = #"([0-9]+) valid identities found"#
        guard let regex = try? NSRegularExpression(pattern: pattern) else {
            return nil
        }
        let range = NSRange(text.startIndex..<text.endIndex, in: text)
        guard let match = regex.firstMatch(in: text, range: range),
              let countRange = Range(match.range(at: 1), in: text) else {
            return nil
        }
        return Int(text[countRange])
    }

    private static func firstNonEmptyLine(in text: String) -> String {
        text
            .split(whereSeparator: \.isNewline)
            .map { String($0).trimmingCharacters(in: .whitespacesAndNewlines) }
            .first { !$0.isEmpty } ?? ""
    }
}
