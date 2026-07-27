import XCTest

final class KLMSiOSUITests: XCTestCase {
    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    @MainActor
    func testCaptureMainScreen() throws {
        try captureMainScreen(runningFixture: false)
    }

    @MainActor
    func testCaptureRunningMainScreen() throws {
        try captureMainScreen(runningFixture: true)
    }

    @MainActor
    func testAdaptiveLayoutPreservesSectionAcrossResize() throws {
        let app = XCUIApplication()
        let isPad = UIDevice.current.userInterfaceIdiom == .pad
        XCUIDevice.shared.orientation = isPad ? .landscapeRight : .portrait
        app.launchArguments.append("KLMS_UI_TEST_CAPTURE")
        app.launch()

        XCTAssertTrue(app.wait(for: .runningForeground, timeout: 12), "KLMS Sync did not enter the foreground.")
        XCTAssertTrue(app.windows.firstMatch.waitForExistence(timeout: 8), "KLMS Sync did not show a window.")

        RunLoop.current.run(until: Date().addingTimeInterval(0.8))

        let initialPrimarySync = identifiedElement("dashboard-primary-full-sync", in: app)
        let initialSyncSection = identifiedElement("dashboard-sync-section", in: app)
        XCTAssertTrue(initialPrimarySync.waitForExistence(timeout: 8), "The primary full-sync action is missing from the dashboard sync section.")
        XCTAssertTrue(initialSyncSection.waitForExistence(timeout: 8), "The dashboard sync section is missing.")
        assertPrimarySyncInsideSection(initialPrimarySync, section: initialSyncSection, in: app)
        let yearScope = identifiedElement("dashboard-scope-year", in: app)
        let semesterScope = identifiedElement("dashboard-scope-semester", in: app)
        XCTAssertTrue(yearScope.waitForExistence(timeout: 8), "The dashboard year scope field is missing.")
        XCTAssertTrue(semesterScope.waitForExistence(timeout: 8), "The dashboard semester scope field is missing.")
        assertMinimumHitTarget(yearScope)
        assertMinimumHitTarget(semesterScope)
        if !isPad {
            let initialScopeSection = identifiedElement("dashboard-scope-section", in: app)
            XCTAssertTrue(initialScopeSection.waitForExistence(timeout: 8), "The dashboard scope section is missing.")
            assertSyncSectionLeadsStack(initialSyncSection, nextSection: initialScopeSection)
        }

        let initialNavigation = identifiedElement(
            isPad ? "companion-sidebar-history" : "companion-compact-tab-history",
            in: app
        )
        XCTAssertTrue(initialNavigation.waitForExistence(timeout: 8), "Expected navigation for the initial width is missing.")
        initialNavigation.tap()

        let historySection = identifiedElement("companion-section-history", in: app)
        XCTAssertTrue(historySection.waitForExistence(timeout: 8), "The log section did not open.")
        let historyPrimarySync = identifiedElement("dashboard-primary-full-sync", in: app)
        XCTAssertFalse(historyPrimarySync.waitForExistence(timeout: 1), "The primary full-sync action must not appear in the log section.")

        XCUIDevice.shared.orientation = isPad ? .portrait : .landscapeRight
        RunLoop.current.run(until: Date().addingTimeInterval(1.0))

        let resizedPrefix = isPad ? "companion-rail" : "companion-compact-tab"
        let resizedNavigation = identifiedElement("\(resizedPrefix)-history", in: app)
        XCTAssertTrue(resizedNavigation.waitForExistence(timeout: 8), "Expected resized navigation did not appear.")
        XCTAssertTrue(historySection.exists, "The selected log section was reset while crossing a layout breakpoint.")
        XCTAssertEqual(resizedNavigation.value as? String, "선택됨")
        attachScreenshot(named: "klms-\(isPad ? "ipad-medium-navigation-rail" : "iphone-landscape-compact-navigation")")
        let resizedPrimarySync = identifiedElement("dashboard-primary-full-sync", in: app)
        XCTAssertFalse(resizedPrimarySync.waitForExistence(timeout: 1), "The primary full-sync action must remain hidden outside the dashboard after resizing.")

        let settingsNavigation = identifiedElement("\(resizedPrefix)-settings", in: app)
        XCTAssertTrue(settingsNavigation.waitForExistence(timeout: 8), "Resized settings navigation is missing.")
        XCTAssertTrue(
            openSection(
                navigationIdentifier: "\(resizedPrefix)-settings",
                sectionIdentifier: "companion-section-settings",
                in: app
            ),
            "The settings navigation did not activate after the layout transition."
        )
        let settingsSection = identifiedElement("companion-section-settings", in: app)
        XCTAssertTrue(settingsSection.waitForExistence(timeout: 8), "The settings section did not open.")
        XCTAssertFalse(
            identifiedElement("dashboard-primary-full-sync", in: app).waitForExistence(timeout: 1),
            "The primary full-sync action must not appear in settings."
        )

        let dashboardNavigation = identifiedElement("\(resizedPrefix)-status", in: app)
        XCTAssertTrue(dashboardNavigation.waitForExistence(timeout: 8), "Resized dashboard navigation is missing.")
        dashboardNavigation.tap()
        let dashboardSection = identifiedElement("companion-section-status", in: app)
        XCTAssertTrue(dashboardSection.waitForExistence(timeout: 8), "The dashboard section did not reopen.")
        let stackedPrimarySync = identifiedElement("dashboard-primary-full-sync", in: app)
        let stackedSyncSection = identifiedElement("dashboard-sync-section", in: app)
        let stackedScopeSection = identifiedElement("dashboard-scope-section", in: app)
        XCTAssertTrue(stackedPrimarySync.waitForExistence(timeout: 8), "The primary full-sync action did not return with the dashboard.")
        XCTAssertTrue(stackedSyncSection.waitForExistence(timeout: 8), "The stacked sync section is missing.")
        XCTAssertTrue(stackedScopeSection.waitForExistence(timeout: 8), "The stacked scope section is missing.")
        assertPrimarySyncInsideSection(stackedPrimarySync, section: stackedSyncSection, in: app)
        assertSyncSectionLeadsStack(stackedSyncSection, nextSection: stackedScopeSection)

        if isPad {
            XCUIDevice.shared.orientation = .landscapeRight
            RunLoop.current.run(until: Date().addingTimeInterval(1.0))
            let restoredWideNavigation = identifiedElement("companion-sidebar-status", in: app)
            XCTAssertTrue(restoredWideNavigation.waitForExistence(timeout: 8), "Wide sidebar did not return after resizing.")
            XCTAssertTrue(dashboardSection.exists, "The selected dashboard section was reset when returning to wide layout.")
            XCTAssertEqual(restoredWideNavigation.value as? String, "선택됨")
            attachScreenshot(named: "klms-ipad-wide-navigation-sidebar")
            let restoredPrimarySync = identifiedElement("dashboard-primary-full-sync", in: app)
            let restoredSyncSection = identifiedElement("dashboard-sync-section", in: app)
            XCTAssertTrue(restoredPrimarySync.waitForExistence(timeout: 8), "The primary full-sync action disappeared when returning to wide layout.")
            XCTAssertTrue(restoredSyncSection.waitForExistence(timeout: 8), "The wide dashboard sync section disappeared.")
            assertPrimarySyncInsideSection(restoredPrimarySync, section: restoredSyncSection, in: app)
        }
    }

    @MainActor
    func testAllMajorSectionsRemainReachableAndHorizontallyContained() throws {
        let app = XCUIApplication()
        let isPad = UIDevice.current.userInterfaceIdiom == .pad
        XCUIDevice.shared.orientation = isPad ? .landscapeRight : .portrait
        app.launchArguments.append("KLMS_UI_TEST_CAPTURE")
        app.launch()

        XCTAssertTrue(app.wait(for: .runningForeground, timeout: 12))
        let layoutRoot = identifiedElement("companion-layout-root", in: app)
        XCTAssertTrue(layoutRoot.waitForExistence(timeout: 8), "The adaptive layout root is missing.")

        for section in majorSectionIDs {
            let navigation = identifiedElement(
                navigationIdentifier(for: section, usesSidebar: isPad),
                in: app
            )
            XCTAssertTrue(navigation.waitForExistence(timeout: 8), "Missing navigation for \(section).")
            assertMinimumHitTarget(navigation)
            assertHorizontallyContained(navigation, in: app.windows.firstMatch)
            if navigation.value as? String != "선택됨" {
                navigation.tap()
            }

            let sectionElement = identifiedElement("companion-section-\(section)", in: app)
            XCTAssertTrue(sectionElement.waitForExistence(timeout: 8), "The \(section) screen did not open.")
            assertHorizontallyContained(sectionElement, in: layoutRoot)
            RunLoop.current.run(until: Date().addingTimeInterval(0.2))
            attachScreenshot(named: "klms-\(isPad ? "ipad" : "iphone")-section-\(section)")
            if section != "status" {
                XCTAssertFalse(
                    identifiedElement("dashboard-primary-full-sync", in: app).waitForExistence(timeout: 0.25),
                    "The whole-sync action escaped its dashboard sync section while \(section) was selected."
                )
            }

            if isPad {
                assertWorkstationPanels(for: section, in: app, layoutRoot: layoutRoot, stacked: false)
            }
        }

        guard isPad else { return }
        XCUIDevice.shared.orientation = .portrait
        RunLoop.current.run(until: Date().addingTimeInterval(1.0))
        for section in majorSectionIDs {
            let railNavigation = identifiedElement("companion-rail-\(section)", in: app)
            XCTAssertTrue(railNavigation.waitForExistence(timeout: 8), "Medium-width rail navigation is missing for \(section).")
            assertMinimumHitTarget(railNavigation)
            assertHorizontallyContained(railNavigation, in: app.windows.firstMatch)
        }
    }

    @MainActor
    func testWorkstationUsesVerticalFallbackAtNarrowWideBoundary() throws {
        guard UIDevice.current.userInterfaceIdiom == .pad else {
            throw XCTSkip("The exact 1040pt workstation boundary needs an iPad landscape canvas.")
        }
        XCUIDevice.shared.orientation = .landscapeRight

        for boundary in [
            (width: 1_040, stacked: true),
            (width: 1_046, stacked: true),
            (width: 1_047, stacked: true),
            (width: 1_048, stacked: false),
        ] {
            let app = XCUIApplication()
            app.launchArguments = [
                "KLMS_UI_TEST_CAPTURE",
                "KLMS_UI_TEST_LAYOUT_WIDTH=\(boundary.width)",
            ]
            app.launch()
            XCTAssertTrue(app.wait(for: .runningForeground, timeout: 12))

            let layoutRoot = identifiedElement("companion-layout-root", in: app)
            XCTAssertTrue(layoutRoot.waitForExistence(timeout: 8))
            XCTAssertEqual(
                layoutRoot.frame.width,
                CGFloat(boundary.width),
                accuracy: 1.5,
                "The UI-test canvas did not apply the requested workstation width."
            )
            assertHorizontallyContained(layoutRoot, in: app.windows.firstMatch)

            for section in ["files", "notices", "tasks", "calendar"] {
                let navigation = identifiedElement("companion-sidebar-\(section)", in: app)
                XCTAssertTrue(navigation.waitForExistence(timeout: 8), "Wide navigation is missing for \(section).")
                navigation.tap()
                XCTAssertTrue(
                    identifiedElement("companion-section-\(section)", in: app).waitForExistence(timeout: 8),
                    "The \(section) workstation screen did not open at \(boundary.width)pt."
                )
                assertWorkstationPanels(
                    for: section,
                    in: app,
                    layoutRoot: layoutRoot,
                    stacked: boundary.stacked
                )
            }
            attachScreenshot(
                named: "klms-ipad-workstation-\(boundary.width)-\(boundary.stacked ? "stacked" : "columns")"
            )
            app.terminate()
        }
    }

    @MainActor
    func testNavigationStagesAtExactAdaptiveBoundaries() throws {
        let isPad = UIDevice.current.userInterfaceIdiom == .pad
        XCUIDevice.shared.orientation = isPad ? .landscapeRight : .portrait

        let boundaries: [(width: Int, prefix: String)] = isPad ? [
            (719, "companion-compact-tab"),
            (720, "companion-rail"),
            (834, "companion-rail"),
            (1_024, "companion-rail"),
            (1_039, "companion-rail"),
            (1_040, "companion-sidebar"),
            (1_047, "companion-sidebar"),
            (1_048, "companion-sidebar"),
            (1_366, "companion-sidebar"),
        ] : [
            (320, "companion-compact-tab"),
            (375, "companion-compact-tab"),
            (390, "companion-compact-tab"),
            (430, "companion-compact-tab"),
        ]
        for boundary in boundaries {
            let app = XCUIApplication()
            app.launchArguments = [
                "KLMS_UI_TEST_CAPTURE",
                "KLMS_UI_TEST_LAYOUT_WIDTH=\(boundary.width)",
            ]
            app.launch()
            XCTAssertTrue(app.wait(for: .runningForeground, timeout: 12))

            let layoutRoot = identifiedElement("companion-layout-root", in: app)
            XCTAssertTrue(layoutRoot.waitForExistence(timeout: 8))
            XCTAssertEqual(layoutRoot.frame.width, CGFloat(boundary.width), accuracy: 1.5)

            let navigation = identifiedElement("\(boundary.prefix)-history", in: app)
            XCTAssertTrue(navigation.waitForExistence(timeout: 8), "Missing \(boundary.prefix) at \(boundary.width)pt.")
            assertMinimumHitTarget(navigation)
            assertHorizontallyContained(navigation, in: layoutRoot)
            navigation.tap()
            XCTAssertTrue(identifiedElement("companion-section-history", in: app).waitForExistence(timeout: 8))
            XCTAssertEqual(navigation.value as? String, "선택됨")
            attachScreenshot(named: "klms-\(isPad ? "ipad" : "iphone")-navigation-\(boundary.width)-\(boundary.prefix)")

            for unexpectedPrefix in ["companion-compact-tab", "companion-rail", "companion-sidebar"]
                where unexpectedPrefix != boundary.prefix {
                XCTAssertFalse(
                    identifiedElement("\(unexpectedPrefix)-history", in: app).waitForExistence(timeout: 0.25),
                    "Only one navigation presentation may exist at \(boundary.width)pt."
                )
            }
            app.terminate()
        }
    }

    @MainActor
    func testKoreanGuidanceKeepsCompleteClausesContained() throws {
        guard UIDevice.current.userInterfaceIdiom == .phone else {
            throw XCTSkip("The reported Korean wrapping regressions are specific to the narrow iPhone layout.")
        }
        XCUIDevice.shared.orientation = .portrait
        let app = XCUIApplication()
        app.launchArguments = ["KLMS_UI_TEST_CAPTURE"]
        app.launch()
        XCTAssertTrue(app.wait(for: .runningForeground, timeout: 12))

        let settingsNavigation = identifiedElement("companion-compact-tab-settings", in: app)
        XCTAssertTrue(settingsNavigation.waitForExistence(timeout: 8))
        settingsNavigation.tap()
        let settingsSection = identifiedElement("companion-section-settings", in: app)
        XCTAssertTrue(settingsSection.waitForExistence(timeout: 8))
        RunLoop.current.run(until: Date().addingTimeInterval(0.8))
        let settingsCopy = identifiedElement("immediate-settings-summary-copy", in: app)
        XCTAssertTrue(settingsCopy.waitForExistence(timeout: 8))
        XCTAssertTrue(settingsCopy.label.contains("화면 모드는 바로 적용됩니다."))
        XCTAssertTrue(settingsCopy.label.contains("공지 메모는 서버에 저장됩니다."))
        XCTAssertGreaterThan(settingsCopy.frame.height, 24)
        assertHorizontallyContained(settingsCopy, in: settingsSection)
        attachScreenshot(named: "klms-iphone-settings-korean-copy")

        let calendarNavigation = identifiedElement("companion-compact-tab-calendar", in: app)
        XCTAssertTrue(calendarNavigation.waitForExistence(timeout: 8))
        calendarNavigation.tap()
        let calendarSection = identifiedElement("companion-section-calendar", in: app)
        XCTAssertTrue(calendarSection.waitForExistence(timeout: 8))
        RunLoop.current.run(until: Date().addingTimeInterval(0.8))
        let calendarCopy = identifiedElement("calendar-action-help-copy", in: app)
        XCTAssertTrue(calendarCopy.waitForExistence(timeout: 8))
        XCTAssertTrue(calendarCopy.label.contains("일정 변경은 아래에서 처리합니다."))
        XCTAssertTrue(calendarCopy.label.contains("전체 검사는 진단 화면에서 실행합니다."))
        XCTAssertGreaterThan(calendarCopy.frame.height, 24)
        assertHorizontallyContained(calendarCopy, in: calendarSection)
        attachScreenshot(named: "klms-iphone-calendar-korean-copy")
    }

    @MainActor
    func testAX5KeepsSyncActionsAndCompactNavigationReachable() throws {
        let app = XCUIApplication()
        let isPad = UIDevice.current.userInterfaceIdiom == .pad
        XCUIDevice.shared.orientation = isPad ? .landscapeRight : .portrait
        app.launchArguments = ["KLMS_UI_TEST_CAPTURE", "KLMS_UI_TEST_AX5"]
        app.launch()

        XCTAssertTrue(app.wait(for: .runningForeground, timeout: 12))
        let syncSection = identifiedElement("dashboard-sync-section", in: app)
        let primarySync = identifiedElement("dashboard-primary-full-sync", in: app)
        XCTAssertTrue(syncSection.waitForExistence(timeout: 8))
        XCTAssertTrue(primarySync.waitForExistence(timeout: 8))
        assertMinimumHitTarget(primarySync)
        assertPrimarySyncInsideSection(primarySync, section: syncSection, in: app)

        let secondaryActions = ["filesSync", "coreSync", "noticeSync"].map {
            identifiedElement("dashboard-secondary-sync-\($0)", in: app)
        }
        for action in secondaryActions {
            XCTAssertTrue(action.waitForExistence(timeout: 8), "An AX5 secondary sync action is missing.")
            assertMinimumHitTarget(action)
            assertHorizontallyContained(action, in: syncSection)
        }
        for pair in zip(secondaryActions, secondaryActions.dropFirst()) {
            XCTAssertGreaterThanOrEqual(
                pair.1.frame.minY,
                pair.0.frame.maxY - 1,
                "AX5 secondary sync actions must reflow into a vertical stack."
            )
        }

        let navigationPrefix = isPad ? "companion-rail-" : "companion-compact-tab-"
        for section in majorSectionIDs {
            let navigation = identifiedElement("\(navigationPrefix)\(section)", in: app)
            XCTAssertTrue(navigation.waitForExistence(timeout: 8), "AX5 navigation is missing for \(section).")
            assertMinimumHitTarget(navigation)
            assertHorizontallyContained(navigation, in: app.windows.firstMatch)
        }
        if isPad {
            XCTAssertFalse(
                identifiedElement("companion-sidebar-status", in: app).exists,
                "AX5 should use the fixed icon rail instead of clipping sidebar labels."
            )
        }
        attachScreenshot(named: "klms-\(isPad ? "ipad" : "iphone")-ax5-dashboard")
    }

    @MainActor
    func testHistoryClearActionsStayCompactAndRequireConfirmation() throws {
        guard UIDevice.current.userInterfaceIdiom == .phone else {
            throw XCTSkip("The compact destructive-icon hierarchy is specific to the iPhone layout.")
        }

        XCUIDevice.shared.orientation = .portrait
        let app = XCUIApplication()
        app.launchArguments = ["KLMS_UI_TEST_CAPTURE"]
        app.launch()

        XCTAssertTrue(app.wait(for: .runningForeground, timeout: 12))
        let historyNavigation = identifiedElement("companion-compact-tab-history", in: app)
        XCTAssertTrue(historyNavigation.waitForExistence(timeout: 8))
        historyNavigation.tap()
        XCTAssertTrue(identifiedElement("companion-section-history", in: app).waitForExistence(timeout: 8))
        RunLoop.current.run(until: Date().addingTimeInterval(0.5))

        let clearAll = identifiedElement("history-clear-all", in: app)
        XCTAssertTrue(clearAll.waitForExistence(timeout: 8), "The top-level history clear action is missing.")
        XCTAssertTrue(clearAll.isEnabled)
        XCTAssertEqual(clearAll.label, "전체 기록 지우기")
        assertMinimumHitTarget(clearAll)
        XCTAssertLessThanOrEqual(clearAll.frame.width, 44.5, "The trailing clear icon must remain compact instead of reading as a primary action.")
        assertHorizontallyContained(clearAll, in: app.windows.firstMatch)

        let clearSharedRuns = identifiedElement("history-clear-shared-run-logs", in: app)
        XCTAssertTrue(clearSharedRuns.waitForExistence(timeout: 8), "The scoped run-log clear action is missing.")
        XCTAssertEqual(clearSharedRuns.label, "동기화 단계 기록 지우기")
        assertMinimumHitTarget(clearSharedRuns)
        XCTAssertLessThanOrEqual(clearSharedRuns.frame.width, 44.5)

        clearAll.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).tap()
        let confirmation = app.alerts.firstMatch
        XCTAssertTrue(confirmation.waitForExistence(timeout: 4), "Clearing all history must require confirmation.")
        XCTAssertTrue(confirmation.staticTexts["전체 기록을 지울까요?"].exists)
        XCTAssertTrue(confirmation.buttons["전체 기록 지우기"].exists)
        let cancel = confirmation.buttons["취소"]
        XCTAssertTrue(cancel.exists)
        cancel.tap()
        XCTAssertFalse(confirmation.waitForExistence(timeout: 2))

        attachScreenshot(named: "klms-iphone-history-clear-actions")
    }

    @MainActor
    func testLargeDatasetPerformanceLazySearchAndSelectionPreservation() throws {
        let app = XCUIApplication()
        let isPad = UIDevice.current.userInterfaceIdiom == .pad
        XCUIDevice.shared.orientation = isPad ? .landscapeRight : .portrait
        app.launchArguments = ["KLMS_UI_TEST_LARGE_DATASET"]
        app.launch()

        XCTAssertTrue(app.wait(for: .runningForeground, timeout: 12))
        XCTAssertTrue(app.windows.firstMatch.waitForExistence(timeout: 8))

        let evidence = identifiedElement("ui-test-2000-item-performance", in: app)
        XCTAssertTrue(evidence.waitForExistence(timeout: 8), "The 2,000-item performance evidence is missing.")
        guard let metricsJSON = evidence.value as? String,
              let metricsData = metricsJSON.data(using: .utf8) else {
            XCTFail("The 2,000-item performance evidence is not valid UTF-8 JSON.")
            return
        }
        let metrics = try JSONDecoder().decode(LargeDatasetPerformanceMetrics.self, from: metricsData)
        let metricsAttachment = XCTAttachment(string: metricsJSON)
        metricsAttachment.name = "klms-ios-2000-item-performance-ms.json"
        metricsAttachment.lifetime = .keepAlways
        add(metricsAttachment)

        XCTAssertEqual(metrics.schema, "klms-ios-2000-item-v1")
        XCTAssertEqual(metrics.itemCount, 2_000)
        XCTAssertEqual(metrics.initialLazyRenderLimit, 120)
        XCTAssertEqual(metrics.targetGlobalIndex, 1_775)
        XCTAssertEqual(metrics.targetItemID, "perf-file-0355")
        XCTAssertEqual(metrics.searchResultCount, 1)
        XCTAssertTrue(metrics.searchResolvedTarget)
        XCTAssertTrue(metrics.cacheHit)
        for category in ["files", "notices", "assignments", "exams", "helpDesk"] {
            XCTAssertEqual(metrics.categoryCounts[category], 400, "The mixed fixture is unbalanced for \(category).")
        }
        XCTAssertLessThanOrEqual(
            metrics.webSocketSnapshotReconciliationMs,
            metrics.thresholds.webSocketSnapshotReconciliationMs
        )
        XCTAssertLessThanOrEqual(
            metrics.classificationAndFilteringMs,
            metrics.thresholds.classificationAndFilteringMs
        )
        XCTAssertLessThanOrEqual(metrics.cacheWriteAndReadMs, metrics.thresholds.cacheWriteAndReadMs)
        XCTAssertLessThanOrEqual(metrics.searchMs, metrics.thresholds.searchMs)
        XCTAssertLessThanOrEqual(metrics.totalMeasuredMs, metrics.thresholds.totalMeasuredMs)

        let navigationPrefix = isPad ? "companion-sidebar" : "companion-compact-tab"
        let filesNavigation = identifiedElement("\(navigationPrefix)-files", in: app)
        XCTAssertTrue(filesNavigation.waitForExistence(timeout: 8))
        filesNavigation.tap()
        let filesSection = identifiedElement("companion-section-files", in: app)
        XCTAssertTrue(filesSection.waitForExistence(timeout: 8))

        let lazyWindow = identifiedElement("dashboard-lazy-render-window-files", in: app)
        XCTAssertTrue(lazyWindow.waitForExistence(timeout: 8), "The lazy-render evidence marker is missing.")
        XCTAssertTrue(
            waitForValue("120/400", of: lazyWindow, timeout: 8),
            "The file list must expose exactly its first 120 of 400 items before expansion."
        )
        let firstRenderedRow = identifiedElement("dashboard-item-perf-file-0000", in: app)
        XCTAssertTrue(firstRenderedRow.waitForExistence(timeout: 8), "The first lazy row was not rendered.")
        let targetIdentifier = "dashboard-item-\(metrics.targetItemID)"
        XCTAssertFalse(
            identifiedElement(targetIdentifier, in: app).waitForExistence(timeout: 0.5),
            "The target at global index 1,775 must start outside the initial 120-row window."
        )

        let searchField = identifiedElement("companion-search-field", in: app)
        XCTAssertTrue(searchField.waitForExistence(timeout: 8), "The dashboard search field is missing.")
        searchField.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).tap()
        searchField.typeText("PERF-TARGET-1775")
        XCTAssertTrue(app.keyboards.firstMatch.waitForExistence(timeout: 4))
        attachScreenshot(named: screenshotName(prefix: "2000-item-search-keyboard-long-korean-unicode"))
        dismissSearchKeyboard(in: app)

        let searchedTarget = identifiedElement(targetIdentifier, in: app)
        XCTAssertTrue(
            revealByScrollingUp(searchedTarget, in: app, attempts: 4),
            "Search did not materialize the matching row outside the initial lazy range."
        )
        assertHorizontallyContained(searchedTarget, in: filesSection)
        let selectedDetailIdentifier = "dashboard-selected-detail-\(metrics.targetItemID)"
        let selectedDetail = identifiedElement(selectedDetailIdentifier, in: app)
        searchedTarget.tap()
        if !selectedDetail.waitForExistence(timeout: 1) {
            searchedTarget.tap()
        }
        XCTAssertTrue(
            selectedDetail.waitForExistence(timeout: 4),
            "The searched row did not become the focused selection."
        )

        let noticesNavigation = identifiedElement("\(navigationPrefix)-notices", in: app)
        XCTAssertTrue(noticesNavigation.waitForExistence(timeout: 8))
        noticesNavigation.tap()
        XCTAssertTrue(identifiedElement("companion-section-notices", in: app).waitForExistence(timeout: 8))
        filesNavigation.tap()
        XCTAssertTrue(filesSection.waitForExistence(timeout: 8))
        XCTAssertTrue(
            identifiedElement(selectedDetailIdentifier, in: app).waitForExistence(timeout: 8),
            "The selected detail was not restored after section navigation."
        )

        let restoredTarget = identifiedElement(targetIdentifier, in: app)
        if !restoredTarget.waitForExistence(timeout: 1) {
            let restoredSearchField = identifiedElement("companion-search-field", in: app)
            XCTAssertTrue(restoredSearchField.waitForExistence(timeout: 8))
            restoredSearchField.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).tap()
            restoredSearchField.typeText("PERF-TARGET-1775")
            dismissSearchKeyboard(in: app)
        }
        XCTAssertTrue(revealByScrollingUp(restoredTarget, in: app, attempts: 4))
        XCTAssertTrue(
            waitForValue("선택됨", of: restoredTarget, timeout: 4),
            "Selection focus was lost while navigating between sections."
        )
        XCTAssertEqual(filesNavigation.value as? String, "선택됨")
        attachScreenshot(named: screenshotName(prefix: "2000-item-search-selection"))
    }

    @MainActor
    private func captureMainScreen(runningFixture: Bool) throws {
        let app = XCUIApplication()
        app.launchArguments.append("KLMS_UI_TEST_CAPTURE")
        if runningFixture {
            app.launchArguments.append("KLMS_UI_TEST_RUNNING_STATE")
        }
        app.launch()

        XCTAssertTrue(app.wait(for: .runningForeground, timeout: 12), "KLMS Sync did not enter the foreground.")
        XCTAssertTrue(app.windows.firstMatch.waitForExistence(timeout: 8), "KLMS Sync did not show a window.")

        normalizeCaptureOrientation()
        RunLoop.current.run(until: Date().addingTimeInterval(1.0))
        let primarySync = identifiedElement("dashboard-primary-full-sync", in: app)
        let syncSection = identifiedElement("dashboard-sync-section", in: app)
        XCTAssertTrue(primarySync.waitForExistence(timeout: 8), "The primary full-sync action is missing from the dashboard sync section.")
        XCTAssertTrue(syncSection.waitForExistence(timeout: 8), "The dashboard sync section is missing.")
        XCTAssertEqual(primarySync.label, runningFixture ? "전체 동기화 중단" : "전체 동기화 실행")
        assertPrimarySyncInsideSection(primarySync, section: syncSection, in: app)
        attachScreenshot(named: screenshotName(prefix: "main"))
    }

    @MainActor
    private func attachScreenshot(named name: String) {
        let attachment = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }

    @MainActor
    private func waitForValue(_ value: String, of element: XCUIElement, timeout: TimeInterval) -> Bool {
        let expectation = XCTNSPredicateExpectation(
            predicate: NSPredicate(format: "value == %@", value),
            object: element
        )
        return XCTWaiter.wait(for: [expectation], timeout: timeout) == .completed
    }

    @MainActor
    private func openSection(
        navigationIdentifier: String,
        sectionIdentifier: String,
        in app: XCUIApplication
    ) -> Bool {
        for attempt in 0..<2 {
            let navigation = identifiedElement(navigationIdentifier, in: app)
            let hittableExpectation = XCTNSPredicateExpectation(
                predicate: NSPredicate(format: "exists == true AND hittable == true"),
                object: navigation
            )
            guard XCTWaiter.wait(
                for: [hittableExpectation],
                timeout: attempt == 0 ? 2 : 1
            ) == .completed else {
                continue
            }

            if navigation.value as? String != "선택됨" {
                navigation.tap()
            }
            let section = identifiedElement(sectionIdentifier, in: app)
            if waitForValue("선택됨", of: navigation, timeout: 1.5),
               section.waitForExistence(timeout: 1.5) {
                return true
            }
        }
        return false
    }

    @MainActor
    private func dismissSearchKeyboard(in app: XCUIApplication) {
        let dismiss = identifiedElement("companion-search-dismiss-keyboard", in: app)
        XCTAssertTrue(dismiss.waitForExistence(timeout: 4), "The search keyboard dismiss action is missing.")
        dismiss.tap()
        XCTAssertFalse(app.keyboards.firstMatch.waitForExistence(timeout: 2))
    }

    @MainActor
    private func revealByScrollingUp(
        _ element: XCUIElement,
        in app: XCUIApplication,
        attempts: Int
    ) -> Bool {
        if element.waitForExistence(timeout: 0.5) {
            return true
        }
        for _ in 0..<attempts {
            app.swipeUp()
            if element.waitForExistence(timeout: 1) {
                return true
            }
        }
        return false
    }

    @MainActor
    private func screenshotName(prefix: String) -> String {
        let idiom = UIDevice.current.userInterfaceIdiom == .pad ? "ipad" : "iphone"
        let scale = Int(UIScreen.main.scale.rounded())
        return "klms-\(idiom)-\(prefix)-@\(scale)x"
    }

    @MainActor
    private func normalizeCaptureOrientation() {
        guard UIDevice.current.userInterfaceIdiom == .pad else { return }
        XCUIDevice.shared.orientation = .landscapeRight
        RunLoop.current.run(until: Date().addingTimeInterval(0.8))
    }

    private var majorSectionIDs: [String] {
        ["status", "files", "notices", "tasks", "calendar", "history", "settings"]
    }

    private func navigationIdentifier(for section: String, usesSidebar: Bool) -> String {
        "\(usesSidebar ? "companion-sidebar" : "companion-compact-tab")-\(section)"
    }

    @MainActor
    private func identifiedElement(_ identifier: String, in app: XCUIApplication) -> XCUIElement {
        app.descendants(matching: .any).matching(identifier: identifier).firstMatch
    }

    @MainActor
    private func assertWorkstationPanels(
        for section: String,
        in app: XCUIApplication,
        layoutRoot: XCUIElement,
        stacked: Bool,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        let identifiers: (list: String, detail: String)?
        switch section {
        case "files", "notices":
            identifiers = (
                "workstation-category-\(section)-list",
                "workstation-category-\(section)-detail"
            )
        case "tasks":
            identifiers = ("workstation-tasks-list", "workstation-tasks-detail")
        case "calendar":
            identifiers = ("workstation-calendar-list", "workstation-calendar-detail")
        default:
            identifiers = nil
        }
        guard let identifiers else { return }

        let list = identifiedElement(identifiers.list, in: app)
        let detail = identifiedElement(identifiers.detail, in: app)
        XCTAssertTrue(list.waitForExistence(timeout: 8), "Missing \(section) list panel.", file: file, line: line)
        XCTAssertTrue(detail.waitForExistence(timeout: 8), "Missing \(section) detail panel.", file: file, line: line)
        assertHorizontallyContained(list, in: layoutRoot, file: file, line: line)
        assertHorizontallyContained(detail, in: layoutRoot, file: file, line: line)

        if stacked {
            XCTAssertGreaterThanOrEqual(
                detail.frame.minY,
                list.frame.maxY - 1,
                "\(section) detail must stack below its list when usable width is below 778pt.",
                file: file,
                line: line
            )
        } else {
            XCTAssertGreaterThanOrEqual(
                detail.frame.minX,
                list.frame.maxX - 1,
                "\(section) list and detail should use two columns when at least 778pt is available.",
                file: file,
                line: line
            )
        }
    }

    @MainActor
    private func assertHorizontallyContained(
        _ element: XCUIElement,
        in container: XCUIElement,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        let frame = element.frame
        let containerFrame = container.frame
        let tolerance: CGFloat = 1.5
        XCTAssertGreaterThan(frame.width, 0, "The element has no visible width.", file: file, line: line)
        XCTAssertGreaterThan(containerFrame.width, 0, "The container has no visible width.", file: file, line: line)
        XCTAssertGreaterThanOrEqual(frame.minX, containerFrame.minX - tolerance, file: file, line: line)
        XCTAssertLessThanOrEqual(frame.maxX, containerFrame.maxX + tolerance, file: file, line: line)
    }

    @MainActor
    private func assertMinimumHitTarget(
        _ element: XCUIElement,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        XCTAssertGreaterThanOrEqual(element.frame.width, 43.5, "Hit target is narrower than 44pt.", file: file, line: line)
        XCTAssertGreaterThanOrEqual(element.frame.height, 43.5, "Hit target is shorter than 44pt.", file: file, line: line)
    }

    @MainActor
    private func assertPrimarySyncInsideSection(
        _ action: XCUIElement,
        section: XCUIElement,
        in app: XCUIApplication,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        let windowFrame = app.windows.firstMatch.frame
        let actionFrame = action.frame
        let sectionFrame = section.frame
        let tolerance: CGFloat = 1
        XCTAssertGreaterThan(actionFrame.width, 0, "The primary full-sync action has no visible width.", file: file, line: line)
        XCTAssertGreaterThan(actionFrame.height, 0, "The primary full-sync action has no visible height.", file: file, line: line)
        XCTAssertGreaterThan(sectionFrame.width, 0, "The dashboard sync section has no visible width.", file: file, line: line)
        XCTAssertGreaterThan(sectionFrame.height, 0, "The dashboard sync section has no visible height.", file: file, line: line)
        XCTAssertGreaterThanOrEqual(actionFrame.minX, windowFrame.minX, file: file, line: line)
        XCTAssertLessThanOrEqual(actionFrame.maxX, windowFrame.maxX, file: file, line: line)
        XCTAssertGreaterThanOrEqual(actionFrame.minX, sectionFrame.minX - tolerance, file: file, line: line)
        XCTAssertLessThanOrEqual(actionFrame.maxX, sectionFrame.maxX + tolerance, file: file, line: line)
        XCTAssertGreaterThanOrEqual(actionFrame.minY, sectionFrame.minY - tolerance, file: file, line: line)
        XCTAssertLessThanOrEqual(actionFrame.maxY, sectionFrame.maxY + tolerance, file: file, line: line)
    }

    @MainActor
    private func assertSyncSectionLeadsStack(
        _ syncSection: XCUIElement,
        nextSection: XCUIElement,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        XCTAssertLessThanOrEqual(
            syncSection.frame.maxY,
            nextSection.frame.minY + 1,
            "The sync section must lead the dashboard when its sections collapse into one column.",
            file: file,
            line: line
        )
    }

    private struct LargeDatasetPerformanceMetrics: Decodable {
        var schema: String
        var itemCount: Int
        var categoryCounts: [String: Int]
        var initialLazyRenderLimit: Int
        var targetGlobalIndex: Int
        var targetItemID: String
        var searchResultCount: Int
        var searchResolvedTarget: Bool
        var cacheHit: Bool
        var webSocketSnapshotReconciliationMs: Double
        var classificationAndFilteringMs: Double
        var cacheWriteAndReadMs: Double
        var searchMs: Double
        var totalMeasuredMs: Double
        var thresholds: LargeDatasetPerformanceThresholds
    }

    private struct LargeDatasetPerformanceThresholds: Decodable {
        var webSocketSnapshotReconciliationMs: Double
        var classificationAndFilteringMs: Double
        var cacheWriteAndReadMs: Double
        var searchMs: Double
        var totalMeasuredMs: Double
    }
}
