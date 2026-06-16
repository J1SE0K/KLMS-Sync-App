import KLMSShared
import SwiftUI

private enum SettingsTab: String, CaseIterable, Identifiable {
    case login
    case sync
    case notice
    case files
    case app

    var id: String { rawValue }

    static var allCases: [SettingsTab] {
        [.app, .login, .sync, .files, .notice]
    }

    var title: String {
        switch self {
        case .login:
            "로그인"
        case .sync:
            "동기화"
        case .notice:
            "공지"
        case .files:
            "파일"
        case .app:
            "화면/앱"
        }
    }

    var detail: String {
        switch self {
        case .login:
            "인증번호와 로그인 보조"
        case .sync:
            "실행 방식과 Safari 자동화"
        case .notice:
            "Notes 메모 작성 방식"
        case .files:
            "파일 확인과 저장 위치"
        case .app:
            "화면 모드와 앱 관리"
        }
    }

    var scopeLabel: String {
        switch self {
        case .login, .sync, .notice, .files:
            "Mac 설정 파일"
        case .app:
            "바로 반영"
        }
    }

    var systemImage: String {
        switch self {
        case .login:
            "person.badge.key"
        case .sync:
            "arrow.triangle.2.circlepath"
        case .notice:
            "checklist"
        case .files:
            "folder"
        case .app:
            "app.badge"
        }
    }
}

struct SettingsView: View {
    @ObservedObject var model: KLMSMacModel
    @State private var selectedTab: SettingsTab = .app
    @AppStorage("KLMSAppearanceMode") private var appearanceMode = KLMSAppearanceMode.system.rawValue
    private let settingsTabColumns = [
        GridItem(.adaptive(minimum: 104, maximum: 160), spacing: 7),
    ]
    private let settingsActionColumns = [
        GridItem(.adaptive(minimum: 118), spacing: 8),
    ]

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            settingsTabBar
            settingsContentPanel
        }
        .frame(maxWidth: .infinity, minHeight: 520, alignment: .topLeading)
    }

    private var settingsTabBar: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .firstTextBaseline, spacing: 10) {
                Text("설정")
                    .font(.caption.weight(.bold))
                    .foregroundStyle(Color.klmsMacSecondaryText)
                Text("자주 쓰는 값은 위에, 기술적인 값은 접어서 정리했습니다.")
                    .font(.caption2)
                    .foregroundStyle(Color.klmsMacSecondaryText)
                    .fixedSize(horizontal: false, vertical: true)
            }

            LazyVGrid(columns: settingsTabColumns, alignment: .leading, spacing: 7) {
                ForEach(SettingsTab.allCases) { tab in
                    settingsTabButton(tab)
                }
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .topLeading)
        .background(Color.klmsMacCardBackground, in: RoundedRectangle(cornerRadius: 14))
        .overlay {
            RoundedRectangle(cornerRadius: 14)
                .stroke(Color.klmsMacBorder, lineWidth: 1)
        }
    }

    private var settingsContentPanel: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 10) {
                Image(systemName: selectedTab.systemImage)
                    .font(.headline.weight(.semibold))
                    .foregroundStyle(Color.klmsMacCommandAccent)
                    .frame(width: 24)
                VStack(alignment: .leading, spacing: 2) {
                    Text(selectedTab.title)
                        .font(.headline.weight(.bold))
                        .foregroundStyle(Color.klmsMacPrimaryText)
                    Text(selectedTab.detail)
                        .font(.caption)
                        .foregroundStyle(Color.klmsMacSecondaryText)
                }
                Spacer()
                Text(selectedTab.scopeLabel)
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(Color.klmsMacSecondaryText)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 5)
                    .background(Color.klmsMacSubtleCardBackground, in: Capsule())
            }
            .padding(.horizontal, 12)
            .padding(.top, 12)

            selectedSettingsContent
        }
        .background(Color.klmsMacCardBackground, in: RoundedRectangle(cornerRadius: 14))
        .overlay {
            RoundedRectangle(cornerRadius: 14)
                .stroke(Color.klmsMacBorder, lineWidth: 1)
        }
    }

    @ViewBuilder
    private var selectedSettingsContent: some View {
        switch selectedTab {
        case .login:
            loginSettings
        case .sync:
            syncSettings
        case .notice:
            noticeSettings
        case .files:
            fileSettings
        case .app:
            appSettings
        }
    }

    private func settingsTabButton(_ tab: SettingsTab) -> some View {
        let isSelected = selectedTab == tab
        return Button {
            guard selectedTab != tab else { return }
            selectedTab = tab
        } label: {
            HStack(spacing: 7) {
                ZStack {
                    RoundedRectangle(cornerRadius: 8)
                        .fill(
                            isSelected
                                ? Color.klmsMacSelectedBorder.opacity(0.18)
                                : Color.klmsMacSubtleCardBackground.opacity(0.72)
                        )
                    Image(systemName: tab.systemImage)
                        .font(.subheadline.weight(isSelected ? .bold : .semibold))
                        .foregroundStyle(isSelected ? Color.klmsMacSelectedForeground : Color.klmsMacSecondaryText.opacity(0.84))
                }
                .frame(width: 28, height: 28)
                Text(tab.title)
                    .font(.caption.weight(isSelected ? .bold : .semibold))
                    .foregroundStyle(isSelected ? Color.klmsMacSelectedForeground : Color.klmsMacPrimaryText)
                    .lineLimit(1)
                    .minimumScaleFactor(0.86)
            }
            .padding(.horizontal, 9)
            .padding(.vertical, 8)
            .frame(maxWidth: .infinity, minHeight: 42, alignment: .center)
            .background(
                isSelected ? Color.klmsMacSelectedBackground.opacity(0.96) : Color.klmsMacSubtleCardBackground.opacity(0.34),
                in: RoundedRectangle(cornerRadius: 10)
            )
            .overlay(alignment: .bottom) {
                RoundedRectangle(cornerRadius: 2)
                    .fill(isSelected ? Color.klmsMacSelectedBorder : Color.clear)
                    .frame(height: 3)
                    .padding(.horizontal, 10)
            }
            .overlay {
                RoundedRectangle(cornerRadius: 10)
                    .stroke(isSelected ? Color.klmsMacSelectedBorder.opacity(0.92) : Color.klmsMacCommandBorder.opacity(0.42), lineWidth: isSelected ? 1.2 : 1)
            }
            .contentShape(RoundedRectangle(cornerRadius: 10))
        }
        .buttonStyle(KLMSMacSettingsTabButtonStyle())
        .accessibilityLabel(tab.title)
        .accessibilityValue(isSelected ? "선택됨" : "")
    }

    private var loginSettings: some View {
        settingsForm {
            SettingsGroupBox(
                title: "로그인",
                detail: "KLMS 로그인 확인과 인증번호 표시 방식을 정합니다.",
                systemImage: "person.badge.key",
                defaultExpanded: true
            ) {
                configText(
                    "KAIST 아이디",
                    .ssoLoginID,
                    description: "로그인 보조 기능이 Safari에서 KLMS에 접속할 때 사용하는 ID입니다. 비밀번호는 저장하지 않습니다."
                )
                configToggle(
                    "로그인 보조",
                    .loginAssistEnabled,
                    defaultValue: true,
                    description: "동기화 전에 로그인 여부를 확인하고, 필요하면 인증번호를 앱에 표시합니다."
                )
                described(
                    "보조 모드",
                    summary: binding(.loginAssistMode, defaultValue: "manual-digits").wrappedValue == "kaikey-auto" ? "Kaikey 자동" : "수동 인증번호",
                    "수동 인증번호는 앱에 표시된 번호를 휴대폰에서 선택하는 방식입니다. Kaikey 자동은 가능한 경우 그 선택 과정까지 자동으로 처리합니다."
                ) {
                    Picker("보조 모드", selection: binding(.loginAssistMode, defaultValue: "manual-digits")) {
                        Text("수동 인증번호").tag("manual-digits")
                        Text("Kaikey 자동").tag("kaikey-auto")
                    }
                }
                configToggle(
                    "앱이 앞에 없어도 로그인 보조",
                    .loginAssistAllowNoninteractive,
                    defaultValue: true,
                    description: "iPhone 요청처럼 KLMS Sync 창이 앞에 없을 때도 로그인 확인과 인증번호 표시를 허용합니다."
                )
                SettingsHelpText("동기화 중 인증번호가 필요하면 대시보드 맨 위에 바로 표시됩니다.")
            }
        }
    }

    private var syncSettings: some View {
        settingsForm {
            SettingsGroupBox(
                title: "실행 방식",
                detail: "동기화 범위와 캘린더 반영 방식을 정합니다.",
                systemImage: "arrow.triangle.2.circlepath",
                defaultExpanded: true
            ) {
                described(
                    "동기화 모드",
                    summary: settingsModeSummary(binding(.syncMode, defaultValue: "auto").wrappedValue),
                    "자동은 캐시와 변경 여부를 보고 필요한 범위를 고릅니다. 빠른 모드는 기존 데이터를 우선 재사용하고, 전체는 가능한 데이터를 다시 읽습니다."
                ) {
                    Picker("동기화 모드", selection: binding(.syncMode, defaultValue: "auto")) {
                        Text("자동").tag("auto")
                        Text("빠른 모드").tag("quick")
                        Text("전체").tag("full")
                    }
                }
                configToggle(
                    "캘린더 내용이 같으면 건너뛰기",
                    .calendarSkipUnchangedDesired,
                    defaultValue: true,
                    description: "시험과 헬프데스크 일정이 이미 같으면 Calendar 이벤트를 다시 쓰지 않습니다."
                )
            }

            SettingsGroupBox(
                title: "Safari 자동화",
                detail: "KLMS를 읽을 때 쓰는 전용 Safari 창의 동작입니다.",
                systemImage: "safari"
            ) {
                configToggle(
                    "Safari 백그라운드 창 사용",
                    .safariBackgroundWindowEnabled,
                    description: "KLMS를 읽을 때 쓰는 전용 Safari 창을 최소화해 현재 작업 화면을 덜 가리게 합니다."
                )
                described(
                    "Safari 백그라운드 방식",
                    summary: binding(.safariBackgroundWindowMode, defaultValue: "minimize").wrappedValue == "none" ? "사용 안 함" : "최소화",
                    "옆으로 치우는 방식은 쓰지 않습니다. KLMS 전용 Safari 창을 만들고, 필요할 때 최소화한 채 재사용합니다."
                ) {
                    Picker("Safari 백그라운드 방식", selection: binding(.safariBackgroundWindowMode, defaultValue: "minimize")) {
                        Text("최소화").tag("minimize")
                        Text("사용 안 함").tag("none")
                    }
                }
                configToggle(
                    "KLMS Sync Safari 창 재사용",
                    .safariReuseExistingWindowEnabled,
                    description: "사용자가 쓰는 Safari 창 대신 KLMS Sync 전용 창을 다음 실행에서도 재사용합니다."
                )
            }
        }
    }

    private var noticeSettings: some View {
        settingsForm {
            SettingsGroupBox(
                title: "메모 이름",
                detail: "공지와 확인한 공지를 쓸 Apple Notes 메모 이름입니다.",
                systemImage: "note.text",
                defaultExpanded: true
            ) {
                configText(
                    "공지 메모",
                    .noticeNoteName,
                    description: "새 공지와 읽지 않은 공지를 작성할 Apple Notes 메모 이름입니다."
                )
                configText(
                    "확인한 공지 메모",
                    .noticeArchiveNoteName,
                    description: "읽음 처리한 공지를 따로 모아 둘 Apple Notes 메모 이름입니다."
                )
            }

            SettingsGroupBox(
                title: "메모 업데이트",
                detail: "숨김 처리와 변경 없는 메모의 재작성 방식을 정합니다.",
                systemImage: "checklist"
            ) {
                configToggle(
                    "숨긴 공지는 메모에서 제외",
                    .noticeHideHiddenItems,
                    defaultValue: true,
                    description: "앱에서 숨긴 공지는 Notes 메모에 쓰지 않습니다. KLMS 원본 공지는 그대로 둡니다."
                )
                configInvertedToggle(
                    "변경 없어도 공지 메모 다시 쓰기",
                    .noticeStableNoopSkip,
                    defaultValue: true,
                    description: "공지 내용이 같아도 Notes 서식을 다시 적용합니다. 조금 느릴 수 있지만, 깨진 체크리스트나 접기 서식을 복구할 때 도움이 됩니다."
                )
                SettingsHelpText("읽음/중요 표시는 항상 동기화합니다. Notes 메모 자체를 건드리고 싶지 않을 때는 실행 화면에서 ‘공지 메모도 업데이트’를 끄면 됩니다.")
            }
        }
    }

    private var fileSettings: some View {
        settingsForm {
            SettingsGroupBox(
                title: "파일 확인",
                detail: "파일 탐색 방식과 다운로드 건너뛰기 기준입니다.",
                systemImage: "folder.badge.gearshape",
                defaultExpanded: true
            ) {
                described(
                    "파일 탐색 모드",
                    summary: settingsModeSummary(sanitizedBinding(.fileRefreshMode, defaultValue: "auto", allowedValues: ["auto", "quick"]).wrappedValue),
                    "자동은 변경 가능성이 있는 파일 페이지를 더 확인합니다. 빠른 모드는 기존 캐시 재사용을 우선합니다."
                ) {
                    Picker("파일 탐색 모드", selection: sanitizedBinding(.fileRefreshMode, defaultValue: "auto", allowedValues: ["auto", "quick"])) {
                        Text("자동").tag("auto")
                        Text("빠른 모드").tag("quick")
                    }
                }
                configToggle(
                    "파일 변경 없으면 다운로드 확인 건너뛰기",
                    .fileSkipDownloadWhenPreviewEmpty,
                    defaultValue: true,
                    description: "변경량 계산에서 새 파일이나 수정된 파일이 없으면 실제 다운로드 단계를 건너뜁니다."
                )
                configToggle(
                    "주차/출처 폴더 사용",
                    .fileWeeklyFoldersEnabled,
                    defaultValue: true,
                    description: "파일을 과목, 주차 같은 KLMS 출처 구조에 맞춰 정리합니다."
                )
                SettingsHelpText("기본적으로 KLMS 등록 시각과 로컬 파일 상태가 달라진 파일만 처리합니다. KLMS 원본 파일은 삭제하지 않고, 앱의 숨김/휴지통 처리는 Mac 로컬 상태에만 적용됩니다.")
            }

            SettingsGroupBox(
                title: "저장 위치",
                detail: "새 파일 보관함과 격리 폴더 위치입니다.",
                systemImage: "folder"
            ) {
                configText(
                    "새 파일 보관함",
                    .fileNewFilesRoot,
                    description: "새 파일 알림에 사용할 복사본을 저장할 위치입니다. 비워 두면 기본 앱 데이터 폴더를 사용합니다."
                )
                configText(
                    "격리 폴더",
                    .fileQuarantineRoot,
                    description: "파일명이 위험하거나 저장 위치가 예상과 다를 때 따로 보관할 폴더입니다."
                )
            }

            SettingsGroupBox(
                title: "문제 분석용 보관",
                detail: "다운로드 문제를 추적할 때만 켜는 보관 옵션입니다.",
                systemImage: "archivebox"
            ) {
                configToggle(
                    "새 다운로드 임시 폴더 유지",
                    .fileKeepFreshDownloads,
                    description: "이번 실행에서 새로 받은 파일의 임시 복사본을 정리하지 않고 남깁니다."
                )
                configToggle(
                    "임시 다운로드 보관",
                    .filePreserveDownloadArchive,
                    description: "다운로드 중간 파일을 보존합니다. 문제를 분석할 때는 도움이 되지만 저장 공간을 더 사용합니다."
                )
            }
        }
    }

    private var appSettings: some View {
        settingsForm {
            SettingsGroupBox(
                title: "바로 반영되는 설정",
                detail: "화면 모드와 원격 실행 옵션을 모든 기기에 바로 맞춥니다.",
                systemImage: "slider.horizontal.3",
                defaultExpanded: true
            ) {
                described(
                    "색상 모드",
                    summary: KLMSAppearanceMode(rawValue: model.serverRelaySharedAppearanceModeValue)?.title ?? "시스템",
                    "화면 모드는 서버에 바로 저장됩니다. 서버가 연결되어 있으면 iPhone/iPad/Windows도 같은 모드를 따라갑니다."
                ) {
                    Picker("색상 모드", selection: Binding(
                        get: { model.serverRelaySharedAppearanceModeValue },
                        set: { value in
                            appearanceMode = value
                            Task {
                                await model.updateServerRelaySharedAppearanceMode(value)
                            }
                        }
                    )) {
                        ForEach(KLMSAppearanceMode.allCases) { mode in
                            Text(mode.title).tag(mode.rawValue)
                        }
                    }
                    .pickerStyle(.segmented)
                }
                described(
                    "공지 메모 갱신",
                    summary: model.serverRelaySharedNoticeUpdateNotesEnabled ? "켜짐" : "꺼짐",
                    "끄면 iPhone/iPad/Windows에서 실행한 동기화는 Notes 공지 메모 쓰기만 건너뜁니다. 과제, 시험, 파일 수집은 그대로 진행됩니다."
                ) {
                    Toggle(
                        "원격 실행에서 공지 메모도 갱신",
                        isOn: Binding(
                            get: { model.serverRelaySharedNoticeUpdateNotesEnabled },
                            set: { value in
                                Task {
                                    await model.updateServerRelaySharedNoticeUpdateNotes(value)
                                }
                            }
                        )
                    )
                }
            }

            SettingsGroupBox(
                title: "설치와 백업",
                detail: "엔진 설치 정보와 로컬 상태 백업입니다. 필요할 때만 펼치세요.",
                systemImage: "shippingbox"
            ) {
                SettingsDisclosureCard {
                    LabeledContent("엔진 위치") {
                        Text(model.paths.engineRoot.path)
                            .lineLimit(2)
                            .textSelection(.enabled)
                    }
                    LabeledContent("앱 내 엔진 버전") {
                        Text(model.payload?.version ?? "알 수 없음")
                    }
                    LabeledContent("설치된 엔진 버전") {
                        Text(model.appDiagnostics.installedPayloadVersion.isEmpty ? "아직 없음" : model.appDiagnostics.installedPayloadVersion)
                            .lineLimit(2)
                            .textSelection(.enabled)
                    }
                    LabeledContent("앱 경로") {
                        Text(model.appDiagnostics.bundlePath)
                            .lineLimit(2)
                            .textSelection(.enabled)
                    }
                    LabeledContent("코드 서명") {
                        VStack(alignment: .trailing, spacing: 2) {
                            Text(model.appDiagnostics.codeSigning.statusTitle)
                            Text(model.appDiagnostics.codeSigning.statusDetail)
                                .font(.caption)
                                .foregroundStyle(model.appDiagnostics.codeSigning.isAdHoc ? Color.klmsMacWarningBorder : Color.klmsMacSecondaryText)
                                .multilineTextAlignment(.trailing)
                        }
                    }
                    Button("엔진 다시 설치") {
                        Task {
                            await model.installEngine(force: true)
                            await model.reloadEngineState()
                        }
                    }
                    SettingsHelpText("앱에 포함된 최신 코드만 다시 복사합니다. config.env, 인증 상태, runtime, course_files는 덮어쓰지 않습니다.")
                } label: {
                    SettingsDisclosureLabel(
                        title: "엔진 설치 정보",
                        detail: model.appDiagnostics.installedPayloadVersion.isEmpty ? "설치된 버전을 확인하려면 펼치세요." : "설치됨 · \(model.appDiagnostics.installedPayloadVersion)",
                        systemImage: "shippingbox"
                    )
                }

                SettingsDisclosureCard {
                    LabeledContent("최근 백업") {
                        Text(model.latestBackup.map { "\($0.id) · \($0.fileCount)개" } ?? "없음")
                    }
                    HStack {
                        Button {
                            model.createBackup()
                        } label: {
                            Label("백업 만들기", systemImage: "externaldrive.badge.plus")
                        }
                        Button(role: .destructive) {
                            Task {
                                await model.restoreLatestBackup()
                            }
                        } label: {
                            Label("최근 백업 복구", systemImage: "clock.arrow.circlepath")
                        }
                        .disabled(model.latestBackup == nil)
                        .buttonStyle(KLMSMacSettingsButtonStyle(tone: .destructive))
                    }
                    SettingsHelpText("숨김, 완료, 중요 표시처럼 앱에서 편집한 로컬 상태를 복구할 때 사용합니다.")
                } label: {
                    SettingsDisclosureLabel(
                        title: "로컬 상태 백업",
                        detail: model.latestBackup.map { "\($0.fileCount)개 항목 백업 있음" } ?? "백업이 필요할 때만 펼치세요.",
                        systemImage: "externaldrive"
                    )
                }
            }

            SettingsGroupBox(
                title: "설정 저장 방식",
                detail: "config.env를 안전하게 수정하는 방식입니다.",
                systemImage: "doc.text"
            ) {
                SettingsHelpText("Mac 설정 파일에 저장하는 값은 알 수 없는 config.env 항목과 주석을 그대로 보존합니다.")
            }

            relaySettingsCollapsed
        }
    }

    private var relaySettingsCollapsed: some View {
        SettingsGroupBox(
            title: "서버 릴레이",
            detail: model.serverRelayConfigured ? "연결 정보 저장됨" : "서버 연결이 필요할 때만 펼치세요.",
            systemImage: "network"
        ) {
            VStack(alignment: .leading, spacing: 12) {
                SettingsActionGroupBox(
                    title: "연결 정보",
                    detail: "서버 주소와 기기별 토큰을 한곳에서 관리합니다.",
                    systemImage: "link"
                ) {
                    described(
                        "서버 URL",
                        summary: model.serverRelayURL.isEmpty ? "미설정" : "저장됨",
                        "Cloudflare Worker 같은 릴레이 서버 주소입니다. 집 주소나 로컬 IP가 아니라 공개 HTTPS 주소만 입력하세요."
                    ) {
                        settingsTextInput(
                            "서버 URL",
                            text: Binding(
                                get: { model.serverRelayURL },
                                set: { model.setServerRelayURL($0) }
                            )
                        )
                    }
                    described(
                        "클라이언트 토큰",
                        summary: model.serverRelayClientToken.isEmpty ? "미설정" : "저장됨",
                        "iPhone/iPad/Windows에 넣는 토큰입니다. 상태 조회와 실행 요청만 할 수 있습니다."
                    ) {
                        settingsTextInput(
                            "클라이언트 토큰",
                            text: Binding(
                                get: { model.serverRelayClientToken },
                                set: { model.setServerRelayClientToken($0) }
                            ),
                            secure: true
                        )
                    }
                    described(
                        "Mac 전용 토큰",
                        summary: model.serverRelayWorkerToken.isEmpty ? "미설정" : "저장됨",
                        "Mac 앱 전용 토큰입니다. 서버에 상태와 요약 데이터를 올리고 원격 명령을 처리할 때 사용합니다."
                    ) {
                        settingsTextInput(
                            "Mac 전용 토큰",
                            text: Binding(
                                get: { model.serverRelayWorkerToken },
                                set: { model.setServerRelayWorkerToken($0) }
                            ),
                            secure: true
                        )
                    }
                }

                SettingsActionGroupBox(
                    title: "릴레이 동작",
                    detail: "다른 기기가 서버를 통해 Mac 앱에 요청을 보낼 수 있게 합니다.",
                    systemImage: "antenna.radiowaves.left.and.right"
                ) {
                    described(
                        "서버 릴레이 사용",
                        summary: model.serverRelayEnabled ? "켜짐" : "꺼짐",
                        "iPhone/iPad/Windows가 Mac과 같은 네트워크에 없어도 서버를 통해 Mac 앱에 실행 요청과 상태 확인을 보낼 수 있게 합니다."
                    ) {
                        Toggle(
                            "서버 릴레이 사용",
                            isOn: Binding(
                                get: { model.serverRelayEnabled },
                                set: { model.setServerRelayEnabled($0) }
                            )
                        )
                    }
                    SettingsFieldRow(
                        title: "서버 상태",
                        summary: model.serverRelayStatusMessage ?? "대기 중",
                        description: "Mac 앱이 서버 요청을 기다리는지 확인합니다."
                    ) {
                        LabeledContent("서버 상태") {
                            Text(model.serverRelayStatusMessage ?? "대기 중")
                                .foregroundStyle(Color.klmsMacSecondaryText)
                        }
                    }
                }

                SettingsActionGroupBox(
                    title: "서버 확인",
                    detail: "연결 정보를 붙여넣고 서버 응답을 검사합니다.",
                    systemImage: "checkmark.seal"
                ) {
                    LazyVGrid(columns: settingsActionColumns, spacing: 8) {
                        Button {
                            model.pasteServerRelayConnectionInfo()
                        } label: {
                            Label("붙여넣기", systemImage: "doc.on.clipboard")
                        }
                        Button {
                            Task {
                                await model.checkServerRelayConnection()
                            }
                        } label: {
                            Label("연결 확인", systemImage: "checkmark.seal")
                        }
                        .disabled(!model.serverRelayConfigured)
                        Button {
                            Task {
                                await model.checkServerRelayConnection(enableOnSuccess: true)
                            }
                        } label: {
                            Label("확인 후 켜기", systemImage: "bolt.badge.checkmark")
                        }
                        .disabled(!model.serverRelayConfigured)
                    }
                }

                SettingsActionGroupBox(
                    title: "연결 정보 복사",
                    detail: "다른 기기에 넣을 연결 정보를 복사합니다.",
                    systemImage: "doc.on.doc"
                ) {
                    LazyVGrid(columns: settingsActionColumns, spacing: 8) {
                        Button {
                            model.copyServerRelayURL()
                        } label: {
                            Label("URL 복사", systemImage: "link")
                        }
                        .disabled(model.serverRelayURL.isEmpty)
                        Button {
                            model.copyServerRelayConnectionInfo()
                        } label: {
                            Label("연결 정보 복사", systemImage: "doc.on.doc")
                        }
                        .disabled(model.serverRelayURL.isEmpty || model.serverRelayClientToken.isEmpty)
                        Button {
                            model.copyServerRelayClientToken()
                        } label: {
                            Label("클라이언트 토큰", systemImage: "key")
                        }
                        .disabled(model.serverRelayClientToken.isEmpty)
                    }
                }

                SettingsHelpText("복사된 토큰은 보안을 위해 잠시 뒤 클립보드에서 자동으로 지워집니다. 서버에는 실행 요청과 요약 숫자만 저장하고, 원본 로그, KLMS URL, config.env, 파일 경로는 올리지 않습니다.")
            }
        }
    }

    private func settingsForm<Content: View>(@ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            content()
        }
        .padding(.horizontal, 12)
        .padding(.bottom, 12)
        .frame(maxWidth: .infinity, minHeight: 360, alignment: .topLeading)
        .buttonStyle(KLMSMacSettingsButtonStyle())
        .textFieldStyle(.roundedBorder)
        .controlSize(.regular)
    }

    @ViewBuilder
    private func described<Content: View>(
        _ title: String,
        summary: String? = nil,
        _ description: String?,
        defaultExpanded: Bool = false,
        @ViewBuilder content: @escaping () -> Content
    ) -> some View {
        SettingsFieldRow(
            title: title,
            summary: summary,
            description: description,
            defaultExpanded: defaultExpanded
        ) {
            content()
        }
    }

    private func configText(_ title: String, _ key: EnvKnownKey, description: String? = nil) -> some View {
        let value = model.configValue(key)
        let summary = settingsInlineSummary(value)
        return described(title, summary: summary, description) {
            settingsTextInput(title, text: binding(key))
        }
    }

    private func settingsInlineSummary(_ value: String) -> String {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            return "비어 있음"
        }
        if trimmed.contains("/") || trimmed.contains("\\") || trimmed.count > 18 {
            return "저장됨"
        }
        return trimmed
    }

    @ViewBuilder
    private func settingsTextInput(
        _ title: String,
        text: Binding<String>,
        secure: Bool = false
    ) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title)
                .font(.caption.weight(.semibold))
                .foregroundStyle(Color.klmsMacPrimaryText)
            if secure {
                SecureField("입력", text: text)
            } else {
                TextField("입력", text: text)
            }
        }
    }

    private func configToggle(
        _ title: String,
        _ key: EnvKnownKey,
        defaultValue: Bool = false,
        description: String? = nil
    ) -> some View {
        described(title, summary: model.boolConfigValue(key, default: defaultValue) ? "켜짐" : "꺼짐", description) {
            Toggle(title, isOn: boolBinding(key, defaultValue: defaultValue))
        }
    }

    private func configInvertedToggle(
        _ title: String,
        _ key: EnvKnownKey,
        defaultValue: Bool = false,
        description: String? = nil
    ) -> some View {
        described(title, summary: !model.boolConfigValue(key, default: defaultValue) ? "켜짐" : "꺼짐", description) {
            Toggle(title, isOn: invertedBoolBinding(key, defaultValue: defaultValue))
        }
    }

    private func settingsModeSummary(_ value: String) -> String {
        switch value {
        case "quick":
            return "빠른 모드"
        case "full":
            return "전체"
        default:
            return "자동"
        }
    }

    private func binding(_ key: EnvKnownKey, defaultValue: String = "") -> Binding<String> {
        Binding(
            get: {
                let value = model.configValue(key)
                return value.isEmpty ? defaultValue : value
            },
            set: { value in
                model.setConfigValue(value, for: key)
            }
        )
    }

    private func sanitizedBinding(
        _ key: EnvKnownKey,
        defaultValue: String,
        allowedValues: Set<String>
    ) -> Binding<String> {
        Binding(
            get: {
                let value = model.configValue(key)
                return allowedValues.contains(value) ? value : defaultValue
            },
            set: { value in
                model.setConfigValue(allowedValues.contains(value) ? value : defaultValue, for: key)
            }
        )
    }

    private func boolBinding(_ key: EnvKnownKey, defaultValue: Bool = false) -> Binding<Bool> {
        Binding(
            get: {
                model.boolConfigValue(key, default: defaultValue)
            },
            set: { value in
                model.setBoolConfigValue(value, for: key)
            }
        )
    }

    private func invertedBoolBinding(_ key: EnvKnownKey, defaultValue: Bool = false) -> Binding<Bool> {
        Binding(
            get: {
                !model.boolConfigValue(key, default: defaultValue)
            },
            set: { value in
                model.setBoolConfigValue(!value, for: key)
            }
        )
    }

}

private struct SettingsDisclosureLabel: View {
    var title: String
    var detail: String
    var systemImage: String

    var body: some View {
        HStack(spacing: 9) {
            Image(systemName: systemImage)
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(Color.klmsMacCommandAccent)
                .frame(width: 26, height: 26)
                .background(Color.klmsMacSubtleCardBackground, in: RoundedRectangle(cornerRadius: 8))
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(Color.klmsMacPrimaryText)
                Text(detail)
                    .font(.caption)
                    .foregroundStyle(Color.klmsMacSecondaryText)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}

private struct SettingsGroupBox<Content: View>: View {
    var title: String
    var detail: String
    var systemImage: String
    @State private var isExpanded: Bool
    @ViewBuilder var content: () -> Content

    init(
        title: String,
        detail: String,
        systemImage: String,
        defaultExpanded: Bool = false,
        @ViewBuilder content: @escaping () -> Content
    ) {
        self.title = title
        self.detail = detail
        self.systemImage = systemImage
        _isExpanded = State(initialValue: defaultExpanded)
        self.content = content
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Button {
                isExpanded.toggle()
            } label: {
                HStack(alignment: .center, spacing: 10) {
                    SettingsDisclosureLabel(
                        title: title,
                        detail: detail,
                        systemImage: systemImage
                    )
                    Spacer(minLength: 8)
                    SettingsExpansionBadge(isExpanded: isExpanded)
                }
                .contentShape(RoundedRectangle(cornerRadius: 10))
            }
            .buttonStyle(KLMSMacSettingsDisclosureButtonStyle())
            .accessibilityHint(isExpanded ? "설정 묶음 접기" : "설정 묶음 펼치기")

            if isExpanded {
                VStack(alignment: .leading, spacing: 10) {
                    content()
                }
                .transition(.opacity)
            }
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.klmsMacSubtleCardBackground.opacity(isExpanded ? 0.72 : 0.48), in: RoundedRectangle(cornerRadius: 12))
        .overlay(alignment: .leading) {
            RoundedRectangle(cornerRadius: 2)
                .fill(isExpanded ? Color.klmsMacSelectedBorder.opacity(0.86) : Color.clear)
                .frame(width: 3)
                .padding(.vertical, 10)
        }
        .overlay {
            RoundedRectangle(cornerRadius: 12)
                .stroke(
                    isExpanded ? Color.klmsMacSelectedBorder.opacity(0.46) : Color.klmsMacBorder.opacity(0.92),
                    lineWidth: 1
                )
        }
    }
}

private struct SettingsFieldRow<Content: View>: View {
    var title: String
    var summary: String?
    var description: String?
    @State private var isExpanded: Bool
    @ViewBuilder var content: () -> Content

    init(
        title: String,
        summary: String? = nil,
        description: String? = nil,
        defaultExpanded: Bool = false,
        @ViewBuilder content: @escaping () -> Content
    ) {
        self.title = title
        self.summary = summary
        self.description = description
        _isExpanded = State(initialValue: defaultExpanded)
        self.content = content
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            Button {
                isExpanded.toggle()
            } label: {
                HStack(alignment: .center, spacing: 10) {
                    VStack(alignment: .leading, spacing: 3) {
                        Text(title)
                            .font(.caption.weight(.bold))
                            .foregroundStyle(Color.klmsMacPrimaryText)
                        if let description = description?.trimmingCharacters(in: .whitespacesAndNewlines),
                           !description.isEmpty {
                            Text(description)
                                .font(.caption2)
                                .foregroundStyle(Color.klmsMacSecondaryText)
                                .lineLimit(isExpanded ? 3 : 1)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                    Spacer(minLength: 8)
                    if let summary = summary?.trimmingCharacters(in: .whitespacesAndNewlines),
                       !summary.isEmpty {
                        Text(summary)
                            .font(.caption2.weight(.semibold))
                            .foregroundStyle(Color.klmsMacSecondaryText)
                            .lineLimit(1)
                            .minimumScaleFactor(0.75)
                            .padding(.horizontal, 8)
                            .padding(.vertical, 4)
                            .background(Color.klmsMacSubtleCardBackground.opacity(0.74), in: Capsule())
                    }
                    SettingsExpansionBadge(isExpanded: isExpanded)
                }
                .contentShape(RoundedRectangle(cornerRadius: 9))
            }
            .buttonStyle(KLMSMacSettingsDisclosureButtonStyle())
            .accessibilityHint(isExpanded ? "\(title) 설정 접기" : "\(title) 설정 펼치기")

            if isExpanded {
                VStack(alignment: .leading, spacing: 8) {
                    content()
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .padding(9)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Color.klmsMacSubtleCardBackground.opacity(0.52), in: RoundedRectangle(cornerRadius: 9))
                .overlay {
                    RoundedRectangle(cornerRadius: 9)
                        .stroke(Color.klmsMacBorder.opacity(0.50), lineWidth: 1)
                }
                .transition(.opacity)
            }
        }
        .padding(11)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(isExpanded ? Color.klmsMacCardBackground.opacity(0.96) : Color.klmsMacCardBackground.opacity(0.82), in: RoundedRectangle(cornerRadius: 10))
        .overlay(alignment: .leading) {
            RoundedRectangle(cornerRadius: 2)
                .fill(isExpanded ? Color.klmsMacSelectedBorder.opacity(0.72) : Color.clear)
                .frame(width: 3)
                .padding(.vertical, 9)
        }
        .overlay {
            RoundedRectangle(cornerRadius: 10)
                .stroke(isExpanded ? Color.klmsMacSelectedBorder.opacity(0.38) : Color.klmsMacBorder.opacity(0.86), lineWidth: 1)
        }
    }
}

private struct SettingsDisclosureCard<Content: View, Label: View>: View {
    @State private var isExpanded = false
    @ViewBuilder var content: () -> Content
    @ViewBuilder var label: () -> Label

    init(
        @ViewBuilder content: @escaping () -> Content,
        @ViewBuilder label: @escaping () -> Label
    ) {
        self.content = content
        self.label = label
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Button {
                isExpanded.toggle()
            } label: {
                HStack(alignment: .center, spacing: 10) {
                    label()
                    Spacer(minLength: 8)
                    SettingsExpansionBadge(isExpanded: isExpanded)
                }
                .contentShape(RoundedRectangle(cornerRadius: 10))
            }
            .buttonStyle(KLMSMacSettingsDisclosureButtonStyle())
            .accessibilityHint(isExpanded ? "설정 세부 항목 접기" : "설정 세부 항목 펼치기")

            if isExpanded {
                VStack(alignment: .leading, spacing: 10) {
                    content()
                }
                .transition(.opacity)
            }
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.klmsMacSubtleCardBackground.opacity(isExpanded ? 0.78 : 0.54), in: RoundedRectangle(cornerRadius: 12))
        .overlay(alignment: .leading) {
            RoundedRectangle(cornerRadius: 2)
                .fill(isExpanded ? Color.klmsMacSelectedBorder.opacity(0.76) : Color.clear)
                .frame(width: 3)
                .padding(.vertical, 10)
        }
        .overlay {
            RoundedRectangle(cornerRadius: 12)
                .stroke(isExpanded ? Color.klmsMacSelectedBorder.opacity(0.42) : Color.klmsMacBorder.opacity(0.92), lineWidth: 1)
        }
    }
}

private struct SettingsActionGroupBox<Content: View>: View {
    var title: String
    var detail: String
    var systemImage: String
    @State private var isExpanded: Bool
    @ViewBuilder var content: () -> Content

    init(
        title: String,
        detail: String,
        systemImage: String,
        defaultExpanded: Bool = false,
        @ViewBuilder content: @escaping () -> Content
    ) {
        self.title = title
        self.detail = detail
        self.systemImage = systemImage
        _isExpanded = State(initialValue: defaultExpanded)
        self.content = content
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Button {
                isExpanded.toggle()
            } label: {
                HStack(alignment: .center, spacing: 9) {
                    Image(systemName: systemImage)
                        .font(.caption.weight(.bold))
                        .foregroundStyle(isExpanded ? Color.klmsMacSelectedForeground : Color.klmsMacSecondaryText)
                        .frame(width: 24, height: 24)
                        .background(
                            isExpanded
                                ? Color.klmsMacSelectedBackground.opacity(0.74)
                                : Color.klmsMacSubtleCardBackground.opacity(0.82),
                            in: RoundedRectangle(cornerRadius: 7)
                        )
                    VStack(alignment: .leading, spacing: 2) {
                        Text(title)
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(Color.klmsMacPrimaryText)
                        Text(detail)
                            .font(.caption2)
                            .foregroundStyle(Color.klmsMacSecondaryText)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    Spacer(minLength: 8)
                    SettingsExpansionBadge(isExpanded: isExpanded)
                }
                .contentShape(RoundedRectangle(cornerRadius: 8))
            }
            .buttonStyle(KLMSMacSettingsDisclosureButtonStyle())

            if isExpanded {
                content()
                    .padding(9)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(Color.klmsMacSubtleCardBackground.opacity(0.50), in: RoundedRectangle(cornerRadius: 9))
                    .overlay {
                        RoundedRectangle(cornerRadius: 9)
                            .stroke(Color.klmsMacBorder.opacity(0.46), lineWidth: 1)
                    }
                    .transition(.opacity)
            }
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.klmsMacCardBackground.opacity(0.72), in: RoundedRectangle(cornerRadius: 10))
        .overlay(alignment: .leading) {
            RoundedRectangle(cornerRadius: 2)
                .fill(isExpanded ? Color.klmsMacSelectedBorder.opacity(0.66) : Color.clear)
                .frame(width: 3)
                .padding(.vertical, 9)
        }
        .overlay {
            RoundedRectangle(cornerRadius: 10)
                .stroke(isExpanded ? Color.klmsMacSelectedBorder.opacity(0.34) : Color.klmsMacBorder.opacity(0.74), lineWidth: 1)
        }
    }
}

private struct KLMSMacSettingsDisclosureButtonStyle: ButtonStyle {
    @Environment(\.isEnabled) private var isEnabled

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .brightness(configuration.isPressed ? -0.018 : 0)
            .opacity(isEnabled ? (configuration.isPressed ? 0.92 : 1.0) : 0.48)
    }
}

private struct SettingsExpansionBadge: View {
    var isExpanded: Bool

    var body: some View {
        HStack(spacing: 5) {
            Image(systemName: isExpanded ? "chevron.up" : "chevron.down")
                .font(.system(size: 10, weight: .bold))
            Text(isExpanded ? "접기" : "펼치기")
                .font(.caption2.weight(.semibold))
        }
        .foregroundStyle(isExpanded ? Color.klmsMacSelectedForeground : Color.klmsMacSecondaryText)
        .padding(.horizontal, 8)
        .padding(.vertical, 5)
        .background(
            isExpanded ? Color.klmsMacSelectedBackground.opacity(0.78) : Color.klmsMacSubtleCardBackground,
            in: Capsule()
        )
        .overlay {
            Capsule()
                .stroke(
                    isExpanded ? Color.klmsMacSelectedBorder.opacity(0.58) : Color.klmsMacBorder.opacity(0.68),
                    lineWidth: 1
                )
        }
    }
}

private struct SettingsHelpText: View {
    var text: String

    init(_ text: String) {
        self.text = text
    }

    var body: some View {
        Text(text)
            .font(.caption)
            .foregroundStyle(Color.klmsMacSecondaryText)
            .fixedSize(horizontal: false, vertical: true)
    }
}

private struct KLMSMacSettingsTabButtonStyle: ButtonStyle {
    @Environment(\.isEnabled) private var isEnabled

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .brightness(configuration.isPressed ? -0.018 : 0)
            .opacity(isEnabled ? (configuration.isPressed ? 0.96 : 1.0) : 0.45)
    }
}

private enum KLMSMacSettingsButtonTone {
    case soft
    case destructive
}

private struct KLMSMacSettingsButtonStyle: ButtonStyle {
    var tone: KLMSMacSettingsButtonTone = .soft
    @Environment(\.isEnabled) private var isEnabled

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.caption.weight(.semibold))
            .foregroundStyle(foreground)
            .padding(.horizontal, 10)
            .padding(.vertical, 7)
            .background(background(isPressed: configuration.isPressed), in: RoundedRectangle(cornerRadius: 8))
            .overlay {
                RoundedRectangle(cornerRadius: 8)
                    .stroke(border(isPressed: configuration.isPressed), lineWidth: 1)
            }
            .opacity(isEnabled ? (configuration.isPressed ? 0.96 : 1.0) : 0.46)
    }

    private var foreground: Color {
        switch tone {
        case .soft:
            return Color.klmsMacSecondaryCommandButtonForeground
        case .destructive:
            return Color.klmsMacDangerBorder
        }
    }

    private func background(isPressed: Bool) -> Color {
        isPressed ? Color.klmsMacCommandButtonPressedBackground : Color.klmsMacCommandButtonBackground.opacity(0.90)
    }

    private func border(isPressed: Bool) -> Color {
        switch tone {
        case .soft:
            return isPressed ? Color.klmsMacPrimaryCommandButtonBorder.opacity(0.46) : Color.klmsMacCommandButtonBorder.opacity(0.92)
        case .destructive:
            return Color.klmsMacDangerBorder.opacity(isPressed ? 0.78 : 0.48)
        }
    }
}
