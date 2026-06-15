import KLMSShared
import SwiftUI

private enum SettingsTab: String, CaseIterable, Identifiable {
    case login
    case sync
    case notice
    case files
    case relay
    case app

    var id: String { rawValue }

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
        case .relay:
            "서버"
        case .app:
            "앱"
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
        case .relay:
            "iPhone/Windows 연결"
        case .app:
            "화면, 설치, 백업"
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
        case .relay:
            "network"
        case .app:
            "app.badge"
        }
    }
}

struct SettingsView: View {
    @ObservedObject var model: KLMSMacModel
    @State private var selectedTab: SettingsTab = .login
    @AppStorage("KLMSAppearanceMode") private var appearanceMode = KLMSAppearanceMode.system.rawValue

    var body: some View {
        ViewThatFits(in: .horizontal) {
            HStack(alignment: .top, spacing: 12) {
                settingsSidebar
                    .frame(width: 214, alignment: .topLeading)
                settingsContentPanel
                    .frame(maxWidth: .infinity, alignment: .topLeading)
            }
            VStack(alignment: .leading, spacing: 12) {
                settingsSidebar
                settingsContentPanel
            }
        }
        .frame(maxWidth: .infinity, minHeight: 520, alignment: .topLeading)
    }

    private var settingsSidebar: some View {
        VStack(alignment: .leading, spacing: 10) {
            VStack(alignment: .leading, spacing: 4) {
                Text("설정")
                    .font(.caption.weight(.bold))
                    .foregroundStyle(Color.klmsMacSecondaryText)
                Text("앱 안에서 바로 바꿉니다.")
                    .font(.caption2)
                    .foregroundStyle(Color.klmsMacSecondaryText)
                    .fixedSize(horizontal: false, vertical: true)
            }

            VStack(spacing: 7) {
                ForEach(SettingsTab.allCases) { tab in
                    settingsSidebarButton(tab)
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
                Text("앱 내부 설정")
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
        case .relay:
            relaySettings
        case .app:
            appSettings
        }
    }

    private func settingsSidebarButton(_ tab: SettingsTab) -> some View {
        let isSelected = selectedTab == tab
        return Button {
            guard selectedTab != tab else { return }
            selectedTab = tab
        } label: {
            HStack(spacing: 10) {
                ZStack {
                    RoundedRectangle(cornerRadius: 8)
                        .fill(
                            isSelected
                                ? Color.klmsMacSelectedForeground.opacity(0.12)
                                : Color.klmsMacSubtleCardBackground.opacity(0.72)
                        )
                    Image(systemName: tab.systemImage)
                        .font(.subheadline.weight(isSelected ? .bold : .semibold))
                        .foregroundStyle(isSelected ? Color.klmsMacSelectedForeground : Color.klmsMacSecondaryText.opacity(0.84))
                }
                .frame(width: 30, height: 30)
                VStack(alignment: .leading, spacing: 2) {
                    Text(tab.title)
                        .font(.subheadline.weight(isSelected ? .semibold : .regular))
                        .foregroundStyle(isSelected ? Color.klmsMacSelectedForeground : Color.klmsMacPrimaryText)
                    Text(tab.detail)
                        .font(.caption2)
                        .foregroundStyle(isSelected ? Color.klmsMacSelectedForeground.opacity(0.78) : Color.klmsMacSecondaryText)
                        .lineLimit(1)
                }
                Spacer(minLength: 0)
                Image(systemName: "chevron.right")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(isSelected ? Color.klmsMacSelectedBorder : Color.klmsMacSecondaryText.opacity(0.52))
            }
            .padding(.leading, 8)
            .padding(.trailing, 10)
            .padding(.vertical, 9)
            .frame(maxWidth: .infinity, minHeight: 48, alignment: .leading)
            .background(
                isSelected ? Color.klmsMacSelectedBackground : Color.clear,
                in: RoundedRectangle(cornerRadius: 10)
            )
            .overlay(alignment: .leading) {
                RoundedRectangle(cornerRadius: 2)
                    .fill(isSelected ? Color.klmsMacSelectedBorder : Color.clear)
                    .frame(width: 3)
                    .padding(.vertical, 9)
            }
            .overlay {
                RoundedRectangle(cornerRadius: 10)
                    .stroke(isSelected ? Color.klmsMacSelectedBorder : Color.klmsMacCommandBorder.opacity(0.32), lineWidth: 1)
            }
            .shadow(color: isSelected ? Color.black.opacity(0.055) : Color.clear, radius: 8, x: 0, y: 4)
            .contentShape(RoundedRectangle(cornerRadius: 10))
        }
        .buttonStyle(KLMSMacSettingsSidebarButtonStyle())
        .accessibilityLabel(tab.title)
        .accessibilityValue(isSelected ? "선택됨" : "")
    }

    private var loginSettings: some View {
        settingsForm {
            Section("로그인") {
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
                described("수동 인증번호는 앱에 표시된 번호를 휴대폰에서 선택하는 방식입니다. Kaikey 자동은 가능한 경우 그 선택 과정까지 자동으로 처리합니다.") {
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
            }
            Section {
                SettingsHelpText("동기화 중 인증번호가 필요하면 대시보드 맨 위에 바로 표시됩니다.")
            }
        }
    }

    private var syncSettings: some View {
        settingsForm {
            Section("실행 방식") {
                described("자동은 캐시와 변경 여부를 보고 필요한 범위를 고릅니다. 빠른 모드는 기존 데이터를 우선 재사용하고, 전체는 가능한 데이터를 다시 읽습니다.") {
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

            Section("Safari 자동화") {
                configToggle(
                    "Safari 백그라운드 창 사용",
                    .safariBackgroundWindowEnabled,
                    description: "KLMS를 읽을 때 쓰는 전용 Safari 창을 최소화해 현재 작업 화면을 덜 가리게 합니다."
                )
                described("옆으로 치우는 방식은 쓰지 않습니다. KLMS 전용 Safari 창을 만들고, 필요할 때 최소화한 채 재사용합니다.") {
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
            Section("메모 이름") {
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

            Section("메모 업데이트") {
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
            }

            Section {
                SettingsHelpText("읽음/중요 표시는 항상 동기화합니다. Notes 메모 자체를 건드리고 싶지 않을 때는 실행 화면에서 ‘공지 메모도 업데이트’를 끄면 됩니다.")
            }
        }
    }

    private var fileSettings: some View {
        settingsForm {
            Section("파일 확인") {
                described("자동은 변경 가능성이 있는 파일 페이지를 더 확인합니다. 빠른 모드는 기존 캐시 재사용을 우선합니다.") {
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
            }

            Section("저장 위치") {
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

            Section("문제 분석용 보관") {
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

            Section {
                SettingsHelpText("기본적으로 KLMS 등록 시각과 로컬 파일 상태가 달라진 파일만 처리합니다. KLMS 원본 파일은 삭제하지 않고, 앱의 숨김/휴지통 처리는 Mac 로컬 상태에만 적용됩니다.")
            }
        }
    }

    private var relaySettings: some View {
        settingsForm {
            Section("연결 정보") {
                described("Cloudflare Worker 같은 릴레이 서버 주소입니다. 집 주소나 로컬 IP가 아니라 공개 HTTPS 주소만 입력하세요.") {
                    TextField(
                        "서버 URL",
                        text: Binding(
                            get: { model.serverRelayURL },
                            set: { model.setServerRelayURL($0) }
                        )
                    )
                }
                described("iPhone/Windows에 넣는 토큰입니다. 상태 조회와 실행 요청만 할 수 있습니다.") {
                    SecureField(
                        "클라이언트 토큰",
                        text: Binding(
                            get: { model.serverRelayClientToken },
                            set: { model.setServerRelayClientToken($0) }
                        )
                    )
                }
                described("Mac 앱 전용 토큰입니다. 서버에 상태와 요약 데이터를 올리고 원격 명령을 처리할 때 사용합니다.") {
                    SecureField(
                        "Mac 전용 토큰",
                        text: Binding(
                            get: { model.serverRelayWorkerToken },
                            set: { model.setServerRelayWorkerToken($0) }
                        )
                    )
                }
            }

            Section("릴레이 동작") {
                described("iPhone/Windows가 Mac과 같은 네트워크에 없어도 서버를 통해 Mac 앱에 실행 요청과 상태 확인을 보낼 수 있게 합니다.") {
                    Toggle(
                        "서버 릴레이 사용",
                        isOn: Binding(
                            get: { model.serverRelayEnabled },
                            set: { model.setServerRelayEnabled($0) }
                        )
                    )
                }
                LabeledContent("서버 상태") {
                    Text(model.serverRelayStatusMessage ?? "대기 중")
                        .foregroundStyle(Color.klmsMacSecondaryText)
                }
            }

            Section("연결 확인") {
                VStack(alignment: .leading, spacing: 8) {
                    HStack {
                        Button("붙여넣기") {
                            model.pasteServerRelayConnectionInfo()
                        }
                        Button("연결 확인") {
                            Task {
                                await model.checkServerRelayConnection()
                            }
                        }
                        .disabled(!model.serverRelayConfigured)
                        Button("확인 후 켜기") {
                            Task {
                                await model.checkServerRelayConnection(enableOnSuccess: true)
                            }
                        }
                        .disabled(!model.serverRelayConfigured)
                    }
                    SettingsHelpText("붙여넣기는 복사한 서버 연결 정보를 한 번에 입력합니다. 연결 확인은 저장된 URL과 토큰으로 서버 응답만 검사합니다.")
                }

                VStack(alignment: .leading, spacing: 8) {
                    HStack {
                        Button("URL 복사") {
                            model.copyServerRelayURL()
                        }
                        .disabled(model.serverRelayURL.isEmpty)
                        Button("연결 정보 복사") {
                            model.copyServerRelayConnectionInfo()
                        }
                        .disabled(model.serverRelayURL.isEmpty || model.serverRelayClientToken.isEmpty)
                        Button("클라이언트 토큰 복사") {
                            model.copyServerRelayClientToken()
                        }
                        .disabled(model.serverRelayClientToken.isEmpty)
                    }
                    SettingsHelpText("복사된 토큰은 보안을 위해 잠시 뒤 클립보드에서 자동으로 지워집니다.")
                }
            }

            Section {
                SettingsHelpText("iPhone/Windows에는 클라이언트 토큰만 넣습니다. Mac 앱에는 요청을 처리할 Mac 전용 토큰도 함께 넣어야 합니다. 서버에는 실행 요청과 요약 숫자만 저장하고, 원본 로그, KLMS URL, config.env, 파일 경로는 올리지 않습니다.")
            }
        }
    }

    private var appSettings: some View {
        settingsForm {
            Section("화면") {
                Picker("색상 모드", selection: $appearanceMode) {
                    ForEach(KLMSAppearanceMode.allCases) { mode in
                        Text(mode.title).tag(mode.rawValue)
                    }
                }
                .pickerStyle(.segmented)
                SettingsHelpText("시스템은 macOS 설정을 따릅니다. 라이트/다크를 고르면 KLMS Sync 창에서만 바로 적용됩니다.")
            }

            Section("설치") {
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
                SettingsHelpText("엔진 다시 설치는 앱에 포함된 최신 코드만 다시 복사합니다. config.env, 인증 상태, runtime, course_files는 덮어쓰지 않습니다.")
            }

            Section("백업") {
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
                SettingsHelpText("백업은 숨김, 완료, 중요 표시처럼 앱에서 편집한 로컬 상태를 복구할 때 사용합니다.")
            }

            Section {
                SettingsHelpText("저장할 때 알 수 없는 config.env 항목과 주석은 그대로 보존됩니다.")
            }
        }
    }

    private func settingsForm<Content: View>(@ViewBuilder content: () -> Content) -> some View {
        Form {
            content()
        }
        .formStyle(.grouped)
        .buttonStyle(KLMSMacSettingsButtonStyle())
        .scrollContentBackground(.hidden)
        .padding(.horizontal, 8)
        .padding(.bottom, 10)
    }

    @ViewBuilder
    private func described<Content: View>(
        _ description: String?,
        @ViewBuilder content: () -> Content
    ) -> some View {
        if let description, !description.isEmpty {
            VStack(alignment: .leading, spacing: 4) {
                content()
                SettingsHelpText(description)
            }
        } else {
            content()
        }
    }

    private func configText(_ title: String, _ key: EnvKnownKey, description: String? = nil) -> some View {
        described(description) {
            TextField(title, text: binding(key))
        }
    }

    private func configToggle(
        _ title: String,
        _ key: EnvKnownKey,
        defaultValue: Bool = false,
        description: String? = nil
    ) -> some View {
        described(description) {
            Toggle(title, isOn: boolBinding(key, defaultValue: defaultValue))
        }
    }

    private func configInvertedToggle(
        _ title: String,
        _ key: EnvKnownKey,
        defaultValue: Bool = false,
        description: String? = nil
    ) -> some View {
        described(description) {
            Toggle(title, isOn: invertedBoolBinding(key, defaultValue: defaultValue))
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

private struct KLMSMacSettingsSidebarButtonStyle: ButtonStyle {
    @Environment(\.isEnabled) private var isEnabled

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed ? 0.996 : 1.0)
            .brightness(configuration.isPressed ? -0.018 : 0)
            .opacity(isEnabled ? (configuration.isPressed ? 0.96 : 1.0) : 0.45)
            .animation(.linear(duration: 0.04), value: configuration.isPressed)
            .animation(.linear(duration: 0.08), value: isEnabled)
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
            .scaleEffect(configuration.isPressed ? 0.997 : 1.0)
            .opacity(isEnabled ? (configuration.isPressed ? 0.96 : 1.0) : 0.46)
            .animation(.linear(duration: 0.035), value: configuration.isPressed)
            .animation(.linear(duration: 0.08), value: isEnabled)
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
