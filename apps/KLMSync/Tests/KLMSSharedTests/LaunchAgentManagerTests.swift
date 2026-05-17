import KLMSShared
import XCTest

final class LaunchAgentManagerTests: XCTestCase {
    func testRenderedPlistMatchesCurrentLaunchAgentShape() {
        let root = URL(fileURLWithPath: "/Users/example/Library/Application Support/KLMSNotesSync", isDirectory: true)
        let manager = LaunchAgentManager(paths: KLMSPaths(engineRoot: root))

        let plist = manager.renderPlist(label: "com.local.klms-notes-sync")

        XCTAssertTrue(plist.contains("<string>com.local.klms-notes-sync</string>"))
        XCTAssertTrue(plist.contains("<string>/bin/zsh</string>"))
        XCTAssertTrue(plist.contains("<string>/Users/example/Library/Application Support/KLMSNotesSync/src/sh/launch_sync_if_idle.sh</string>"))
        XCTAssertTrue(plist.contains("<key>RunAtLoad</key>"))
        XCTAssertTrue(plist.contains("<key>StartInterval</key>"))
        XCTAssertTrue(plist.contains("<integer>900</integer>"))
    }
}
