import KLMSShared
import SwiftUI

struct SettingsView: View {
    @ObservedObject var model: KLMSMacModel

    var body: some View {
        Form {
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
            }

            Section("로그인") {
                configText("KAIST 아이디", .ssoLoginID)
                configToggle("로그인 보조", .loginAssistEnabled)
                Picker("보조 모드", selection: binding(.loginAssistMode, defaultValue: "manual-digits")) {
                    Text("수동 인증번호").tag("manual-digits")
                    Text("Kaikey 자동").tag("kaikey-auto")
                }
                configToggle("백그라운드 실행 허용", .loginAssistAllowNoninteractive)
            }

            Section("실행") {
                configToggle("자동 실행", .autoSyncEnabled)
                configText("동기화 주기(초)", .syncIntervalSeconds)
                configText("유휴 조건(초)", .minIdleSeconds)
                configToggle("사용자 활동 시 자동실행 중단", .syncAbortOnUserActivity)
                configText("중단 유휴 기준(초)", .syncActiveAbortIdleSeconds)
                configToggle("Safari 백그라운드 창 사용", .safariBackgroundWindowEnabled)
                configToggle("기존 Safari KLMS 창 재사용", .safariReuseExistingWindowEnabled)
                configToggle("캘린더 내용 같으면 건너뛰기", .calendarSkipUnchangedDesired, defaultValue: true)
                Picker("동기화 모드", selection: binding(.syncMode, defaultValue: "auto")) {
                    Text("자동").tag("auto")
                    Text("빠르게").tag("quick")
                    Text("전체").tag("full")
                }
                Picker("파일 탐색 모드", selection: sanitizedBinding(.fileRefreshMode, defaultValue: "auto", allowedValues: ["auto", "quick"])) {
                    Text("자동").tag("auto")
                    Text("빠르게").tag("quick")
                }
            }

            Section("iPhone") {
                Toggle(
                    "로컬 원격 제어",
                    isOn: Binding(
                        get: { model.localRemoteEnabled },
                        set: { model.setLocalRemoteEnabled($0) }
                    )
                )
                LabeledContent("로컬 상태") {
                    Text(model.localRemoteStatusMessage ?? "대기 중")
                        .foregroundStyle(.secondary)
                }
                if model.localRemoteEnabled {
                    LabeledContent("Mac 주소") {
                        HStack(spacing: 6) {
                            Text(model.localRemotePrimaryEndpoint)
                                .font(.caption.monospaced())
                                .textSelection(.enabled)
                            Button("복사") {
                                model.copyLocalRemoteEndpoint()
                            }
                            .font(.caption)
                        }
                    }
                    LabeledContent("토큰") {
                        HStack {
                            Text(model.localRemoteToken)
                                .font(.caption.monospaced())
                                .textSelection(.enabled)
                            Button("복사") {
                                model.copyLocalRemoteToken()
                            }
                            Button("재생성") {
                                model.regenerateLocalRemoteToken()
                            }
                        }
                    }
                    LabeledContent("연결 정보") {
                        Button("주소와 토큰 복사") {
                            model.copyLocalRemoteConnectionInfo()
                        }
                    }
                }
                Text("무료 Apple ID에서는 이 로컬 원격 제어를 사용합니다. iPhone과 Mac이 같은 Wi-Fi에 있어야 하며, iPhone 앱에 Mac 주소와 토큰을 입력합니다.")
                    .font(.caption)
                    .foregroundStyle(.secondary)

                LabeledContent("CloudKit 권한") {
                    Text(model.appDiagnostics.codeSigning.cloudKitEntitled ? "설정됨" : "설정 필요")
                        .foregroundStyle(model.appDiagnostics.codeSigning.cloudKitEntitled ? Color.secondary : Color.orange)
                }
                Toggle(
                    "CloudKit 요청 자동 처리",
                    isOn: Binding(
                        get: { model.remoteProcessingEnabled },
                        set: { model.setRemoteProcessingEnabled($0) }
                    )
                )
                .disabled(!model.appDiagnostics.codeSigning.cloudKitEntitled)
                LabeledContent("처리 상태") {
                    Text(model.remoteProcessingStatusMessage ?? "대기 중")
                        .foregroundStyle(.secondary)
                }
                if let remote = model.lastRemoteCommand {
                    LabeledContent("최근 요청") {
                        Text("\(remote.kind.displayName) · \(remote.status.displayName)")
                            .foregroundStyle(.secondary)
                    }
                }
                Text("CloudKit은 유료 Apple Developer 팀과 iCloud container/provisioning이 있을 때만 사용합니다.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section("파일") {
                configToggle("파일 변경 없으면 다운로드 확인 건너뛰기", .fileSkipDownloadWhenPreviewEmpty, defaultValue: true)
                configToggle("새 다운로드 임시 폴더 유지", .fileKeepFreshDownloads)
                configToggle("주차/출처 폴더 사용", .fileWeeklyFoldersEnabled)
                configToggle("임시 다운로드 보관", .filePreserveDownloadArchive)
                configText("새 파일 보관함", .fileNewFilesRoot)
                configText("격리 폴더", .fileQuarantineRoot)
            }

            Section("공지") {
                configText("공지 메모", .noticeNoteName)
                configText("확인한 공지 메모", .noticeArchiveNoteName)
                LabeledContent("앱 공지 메모 작성") {
                    Text("체크리스트/문단 형식")
                        .foregroundStyle(.blue)
                }
                Text("앱에서 공지 동기화를 실행하면 앱 대시보드의 읽음/중요 상태를 기준으로 Notes 체크리스트와 문단 구분을 다시 작성합니다.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                configToggle("숨긴 공지는 메모에서 제외", .noticeHideHiddenItems, defaultValue: true)
                configInvertedToggle("변경 없어도 공지 메모 다시 쓰기", .noticeStableNoopSkip, defaultValue: true)
                configToggle("매번 읽음/중요 체크 읽기", .noticeAlwaysCaptureState, defaultValue: true)
                configToggle("변경 없어서 건너뛸 때 메모 양식 검사", .noticeVerifyStableSkipFormat, defaultValue: false)
            }

            Section("기타") {
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
                Text("알 수 없는 config.env 항목과 주석은 저장할 때 그대로 보존됩니다.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Text("파일 휴지통 이동은 로컬 파일만 대상으로 하며 KLMS 원본 데이터는 삭제하지 않습니다.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .padding()
    }

    private func configText(_ title: String, _ key: EnvKnownKey) -> some View {
        TextField(title, text: binding(key))
    }

    private func configToggle(_ title: String, _ key: EnvKnownKey, defaultValue: Bool = false) -> some View {
        Toggle(title, isOn: boolBinding(key, defaultValue: defaultValue))
    }

    private func configInvertedToggle(_ title: String, _ key: EnvKnownKey, defaultValue: Bool = false) -> some View {
        Toggle(title, isOn: invertedBoolBinding(key, defaultValue: defaultValue))
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
