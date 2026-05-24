import Foundation
import CoreFoundation

public extension String {
    var klmsDisplayText: String {
        klmsRepairingCommonMojibake.precomposedStringWithCanonicalMapping
    }

    var klmsLocalizedStatus: String {
        switch klmsDisplayText.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() {
        case "ok":
            "정상"
        case "missing":
            "없음"
        case "warn", "warning":
            "주의"
        case "fail", "failed", "error":
            "실패"
        case "pending":
            "대기 중"
        case "running":
            "실행 중"
        case "completed":
            "완료"
        case "macunavailable", "mac_unavailable":
            "Mac 응답 없음"
        case "":
            ""
        default:
            klmsDisplayText
        }
    }

    var klmsDisplayStageName: String {
        let raw = klmsDisplayText.trimmingCharacters(in: .whitespacesAndNewlines)
        let normalized = raw
            .replacingOccurrences(of: "_", with: "-")
            .lowercased()
        switch normalized {
        case "dashboard-fetch", "notice-dashboard-fetch":
            return "대시보드 읽기"
        case "course-list", "notice-course-list":
            return "과목 목록 정리"
        case "course-fetch", "notice-course-fetch":
            return "과목 페이지 읽기"
        case "all-week-course-fetch", "notice-all-week-course-fetch":
            return "전체 주차 페이지 읽기"
        case "detail-list":
            return "과제 상세 목록 정리"
        case "details-fetch":
            return "과제 상세 읽기"
        case "notice-summary", "notice-summary-prebuild":
            return "공지 요약 만들기"
        case "notice-native-render", "update-notice-native-note":
            return "공지 메모 작성"
        case "completed-reminders-import":
            return "완료된 미리 알림 읽기"
        case "calendar-sync":
            return "캘린더 반영"
        case "reminders-sync":
            return "미리 알림 반영"
        case "files-course-pages":
            return "파일 과목 페이지 읽기"
        case "files-all-week-course-pages":
            return "파일 전체 주차 읽기"
        case "files-seed-pages":
            return "파일 후보 페이지 읽기"
        case "files-nested-pages", "files-nested-round2-pages":
            return "파일 하위 페이지 읽기"
        case "manifest-build":
            return "파일 목록 만들기"
        case "file-preview":
            return "파일 변경 미리보기"
        case "download":
            return "파일 다운로드"
        case "prune":
            return "사라진 파일 정리"
        case "archive-prune":
            return "임시 다운로드 정리"
        case "cleanup":
            return "다운로드 정리"
        default:
            return raw
                .replacingOccurrences(of: "-", with: " ")
                .replacingOccurrences(of: "_", with: " ")
        }
    }
}

public extension Data {
    var klmsDecodedDisplayText: String {
        KLMSDisplayTextDecoder.decode(self)
    }
}

private extension String {
    var klmsRepairingCommonMojibake: String {
        let normalized = precomposedStringWithCanonicalMapping
        guard normalized.klmsLooksLikeMojibake else {
            return normalized
        }
        let candidates = [String.Encoding.windowsCP1252, .isoLatin1, .macOSRoman]
            .compactMap { encoding -> String? in
                guard let data = normalized.data(using: encoding),
                      let repaired = String(data: data, encoding: .utf8) else {
                    return nil
                }
                return repaired
            }
        return candidates.max { lhs, rhs in
            lhs.klmsDisplayRepairScore < rhs.klmsDisplayRepairScore
        }
        .flatMap { $0.klmsDisplayRepairScore > normalized.klmsDisplayRepairScore ? $0 : nil }
        ?? normalized
    }

    var klmsLooksLikeMojibake: Bool {
        let markers = ["ì", "ê", "ë", "í", "Ã", "Â", "â", "€", "œ", "š", "§", "µ", "³", "�"]
        return markers.contains { contains($0) }
    }

    var klmsDisplayRepairScore: Int {
        (klmsHangulScalarCount * 5) - (klmsMojibakeMarkerCount * 2)
    }

    var klmsHangulScalarCount: Int {
        unicodeScalars.reduce(0) { total, scalar in
            let value = scalar.value
            let isHangul = (0xAC00...0xD7A3).contains(value)
                || (0x1100...0x11FF).contains(value)
                || (0x3130...0x318F).contains(value)
            return total + (isHangul ? 1 : 0)
        }
    }

    var klmsMojibakeMarkerCount: Int {
        unicodeScalars.reduce(0) { total, scalar in
            let value = scalar.value
            let isMarker = value == 0xFFFD
                || (0x00C0...0x00FF).contains(value)
                || (0x20A0...0x20CF).contains(value)
                || (0x02B0...0x02FF).contains(value)
            return total + (isMarker ? 1 : 0)
        }
    }
}

private enum KLMSDisplayTextDecoder {
    static func decode(_ data: Data) -> String {
        for encoding in textEncodings {
            if let text = String(data: data, encoding: encoding) {
                return text.klmsDisplayText
            }
        }
        return String(decoding: data, as: UTF8.self).klmsDisplayText
    }

    private static let textEncodings: [String.Encoding] = {
        let names = ["UTF-8", "EUC-KR", "windows-949", "ks_c_5601-1987", "x-mac-korean"]
        let koreanEncodings = names.compactMap { name -> String.Encoding? in
            let cfEncoding = CFStringConvertIANACharSetNameToEncoding(name as CFString)
            guard cfEncoding != kCFStringEncodingInvalidId else {
                return nil
            }
            let nsEncoding = CFStringConvertEncodingToNSStringEncoding(cfEncoding)
            return String.Encoding(rawValue: nsEncoding)
        }
        var encodings = koreanEncodings + [.utf8, .windowsCP1252, .isoLatin1, .macOSRoman]
        var seen = Set<UInt>()
        encodings.removeAll { encoding in
            !seen.insert(encoding.rawValue).inserted
        }
        return encodings
    }()
}
