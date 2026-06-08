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
}

struct SettingsView: View {
    @ObservedObject var model: KLMSMacModel
    @State private var selectedTab: SettingsTab = .login

    var body: some View {
        VStack(spacing: 0) {
            TabView(selection: $selectedTab) {
                loginSettings
                    .tabItem {
                        Label("로그인", systemImage: "person.badge.key")
                    }
                    .tag(SettingsTab.login)
                syncSettings
                    .tabItem {
                        Label("동기화", systemImage: "arrow.triangle.2.circlepath")
                    }
                    .tag(SettingsTab.sync)
                noticeSettings
                    .tabItem {
                        Label("공지", systemImage: "checklist")
                    }
                    .tag(SettingsTab.notice)
                fileSettings
                    .tabItem {
                        Label("파일", systemImage: "folder")
                    }
                    .tag(SettingsTab.files)
                relaySettings
                    .tabItem {
                        Label("서버", systemImage: "network")
                    }
                    .tag(SettingsTab.relay)
                appSettings
                    .tabItem {
                        Label("앱", systemImage: "app.badge")
                    }
                    .tag(SettingsTab.app)
            }
        }
        .frame(minWidth: 620, minHeight: 520)
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
                    description: "동기화 전에 로그인 여부를 확인하고, 필요하면 인증번호를 앱에 표시합니다."
                )
                described("수동 인증번호는 앱에 표시된 번호를 휴대폰에서 선택하는 방식입니다. Kaikey 자동은 가능한 경우 그 선택 과정까지 자동으로 처리합니다.") {
                    Picker("보조 모드", selection: binding(.loginAssistMode, defaultValue: "manual-digits")) {
                        Text("수동 인증번호").tag("manual-digits")
                        Text("Kaikey 자동").tag("kaikey-auto")
                    }
                }
                configToggle(
                    "백그라운드 실행 허용",
                    .loginAssistAllowNoninteractive,
                    description: "자동 실행이나 iPhone 요청처럼 앱 창이 앞에 없을 때도 로그인 보조를 허용합니다."
                )
            }
            Section {
                SettingsHelpText("인증번호 표시와 로그인 보조 설정은 이 화면에서만 관리합니다. 동기화 중 필요한 인증번호는 대시보드 상단에 바로 표시됩니다.")
            }
        }
    }

    private var syncSettings: some View {
        settingsForm {
            Section("자동 실행") {
                configToggle(
                    "자동 실행",
                    .autoSyncEnabled,
                    description: "Mac이 켜져 있고 사용자 세션이 살아 있을 때 자동 실행 서비스가 주기적으로 동기화를 시도합니다."
                )
                configText(
                    "동기화 주기(초)",
                    .syncIntervalSeconds,
                    description: "자동 실행이 다음 실행 여부를 확인하는 간격입니다. 수동 실행 버튼에는 영향을 주지 않습니다."
                )
                configText(
                    "유휴 조건(초)",
                    .minIdleSeconds,
                    description: "키보드나 마우스를 이 시간 이상 사용하지 않았을 때만 자동 실행을 허용합니다."
                )
                configToggle(
                    "사용자 활동 시 자동실행 중단",
                    .syncAbortOnUserActivity,
                    description: "자동 동기화 중 사용자가 Mac을 다시 사용하면 Safari와 Notes가 방해되지 않도록 실행을 멈춥니다."
                )
                configText(
                    "중단 유휴 기준(초)",
                    .syncActiveAbortIdleSeconds,
                    description: "자동 실행 중 사용자 활동으로 판단할 기준입니다. 값이 작을수록 더 빨리 중단합니다."
                )
            }

            Section("실행 방식") {
                described("자동은 캐시와 변경 여부를 보고 필요한 범위를 고릅니다. 빠르게는 기존 데이터를 우선 재사용하고, 전체는 가능한 데이터를 다시 읽습니다.") {
                    Picker("동기화 모드", selection: binding(.syncMode, defaultValue: "auto")) {
                        Text("자동").tag("auto")
                        Text("빠르게").tag("quick")
                        Text("전체").tag("full")
                    }
                }
                configToggle(
                    "Safari 백그라운드 창 사용",
                    .safariBackgroundWindowEnabled,
                    description: "KLMS를 읽을 때 사용하는 Safari 전용 창을 최소화해서 작업 화면을 방해하지 않게 합니다."
                )
                described("옆으로 치우는 방식은 사용하지 않습니다. 앱은 KLMS 전용 Safari 창을 만들고 최소화한 상태로 재사용합니다.") {
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
                configToggle(
                    "캘린더 내용 같으면 건너뛰기",
                    .calendarSkipUnchangedDesired,
                    defaultValue: true,
                    description: "시험과 헬프데스크 일정이 이미 같으면 캘린더 이벤트를 다시 쓰지 않습니다."
                )
            }
        }
    }

    private var noticeSettings: some View {
        settingsForm {
            Section("메모") {
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
                configToggle(
                    "숨긴 공지는 메모에서 제외",
                    .noticeHideHiddenItems,
                    defaultValue: true,
                    description: "앱에서 숨긴 공지는 Notes 메모에 쓰지 않습니다. KLMS 원본은 건드리지 않습니다."
                )
                configInvertedToggle(
                    "변경 없어도 공지 메모 다시 쓰기",
                    .noticeStableNoopSkip,
                    defaultValue: true,
                    description: "동기화할 때마다 Notes 체크리스트 상태를 다시 읽어 읽음/중요 표시를 유지합니다. 공지 내용이 같아도 Notes 서식을 다시 적용하면 조금 느릴 수 있지만 깨진 서식을 복구하는 데 도움이 됩니다."
                )
            }

            Section {
                SettingsHelpText("공지 메모는 체크리스트와 문단 구분을 기본 서식으로 사용합니다. 읽음/중요 상태는 항상 동기화합니다. 메모 자체를 건드리지 않으려면 실행 화면에서 '공지 메모도 업데이트'를 끄세요.")
            }
        }
    }

    private var fileSettings: some View {
        settingsForm {
            Section("탐색") {
                described("자동은 변경 가능성이 있는 파일 페이지를 더 확인합니다. 빠르게는 기존 캐시 재사용을 우선합니다.") {
                    Picker("파일 탐색 모드", selection: sanitizedBinding(.fileRefreshMode, defaultValue: "auto", allowedValues: ["auto", "quick"])) {
                        Text("자동").tag("auto")
                        Text("빠르게").tag("quick")
                    }
                }
                configToggle(
                    "파일 변경 없으면 다운로드 확인 건너뛰기",
                    .fileSkipDownloadWhenPreviewEmpty,
                    defaultValue: true,
                    description: "변경량 계산에서 새 파일이나 수정된 파일이 없으면 실제 다운로드 단계를 건너뜁니다."
                )
            }

            Section("저장") {
                configToggle(
                    "새 다운로드 임시 폴더 유지",
                    .fileKeepFreshDownloads,
                    description: "이번 실행에서 새로 받은 파일의 임시 복사본을 정리하지 않고 남깁니다."
                )
                configToggle(
                    "주차/출처 폴더 사용",
                    .fileWeeklyFoldersEnabled,
                    defaultValue: true,
                    description: "파일 목록을 과목, 주차 같은 KLMS 출처 구조에 맞춰 정리합니다."
                )
                configToggle(
                    "임시 다운로드 보관",
                    .filePreserveDownloadArchive,
                    description: "다운로드 중간 파일을 보존합니다. 문제를 분석할 때는 도움이 되지만 저장 공간을 더 사용합니다."
                )
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

            Section {
                SettingsHelpText("기본적으로 새로 확인됐거나 변경된 파일만 처리합니다. KLMS 원본 파일은 삭제하지 않으며, 앱의 숨김/휴지통 처리는 Mac 로컬 상태에만 적용됩니다.")
            }
        }
    }

    private var relaySettings: some View {
        settingsForm {
            Section("서버 릴레이") {
                described("iPhone/Windows가 Mac과 같은 네트워크에 없어도 서버를 통해 Mac 앱에 실행 요청과 상태 확인을 보낼 수 있게 합니다.") {
                    Toggle(
                        "서버 릴레이 사용",
                        isOn: Binding(
                            get: { model.serverRelayEnabled },
                            set: { model.setServerRelayEnabled($0) }
                        )
                    )
                }
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
                LabeledContent("서버 상태") {
                    Text(model.serverRelayStatusMessage ?? "대기 중")
                        .foregroundStyle(.secondary)
                }
            }

            Section("연결") {
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
                            .foregroundStyle(model.appDiagnostics.codeSigning.isAdHoc ? .orange : .secondary)
                            .multilineTextAlignment(.trailing)
                    }
                }
                Button("엔진 다시 설치") {
                    Task {
                        await model.installEngine(force: true)
                        await model.refresh()
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
        .padding()
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
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
    }
}
