import KLMSShared
import XCTest

final class EnvDocumentTests: XCTestCase {
    func testUpdatesKnownKeyWhilePreservingCommentsAndUnknownKeys() {
        var document = EnvDocument(
            text: """
            # keep this comment
            SYNC_MODE="auto"
            UNKNOWN_FEATURE="leave-me"
            export KLMS_LOGIN_ASSIST_ENABLED="0"
            """
        )

        document.setValue("full", for: .syncMode)
        document.setBool(true, for: .loginAssistEnabled)
        document.setValue("manual-digits", for: .loginAssistMode)
        document.setBool(false, for: .noticeStableNoopSkip)
        document.setBool(true, for: .noticePreformattedPasteOnly)
        document.setBool(true, for: .noticePlainTextPaste)

        XCTAssertTrue(document.text.contains("# keep this comment"))
        XCTAssertTrue(document.text.contains("UNKNOWN_FEATURE=\"leave-me\""))
        XCTAssertTrue(document.text.contains("SYNC_MODE=\"full\""))
        XCTAssertTrue(document.text.contains("export KLMS_LOGIN_ASSIST_ENABLED=\"1\""))
        XCTAssertTrue(document.text.contains("KLMS_LOGIN_ASSIST_MODE=\"manual-digits\""))
        XCTAssertTrue(document.text.contains("NOTICE_NATIVE_STABLE_NOOP_SKIP=\"0\""))
        XCTAssertTrue(document.text.contains("NOTICE_NATIVE_PREFORMATTED_PASTE_ONLY=\"1\""))
        XCTAssertTrue(document.text.contains("NOTICE_NATIVE_PLAIN_TEXT_PASTE=\"1\""))
    }

    func testParsesQuotedAndUnquotedValues() {
        let document = EnvDocument(
            text: """
            A=plain
            B="two words"
            C='single quoted'
            """
        )

        XCTAssertEqual(document.value(for: "A"), "plain")
        XCTAssertEqual(document.value(for: "B"), "two words")
        XCTAssertEqual(document.value(for: "C"), "single quoted")
    }
}
