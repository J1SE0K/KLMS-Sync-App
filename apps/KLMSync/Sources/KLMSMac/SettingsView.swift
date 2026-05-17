import KLMSShared
import SwiftUI

struct SettingsView: View {
    @ObservedObject var model: KLMSMacModel

    var body: some View {
        Form {
            Section("설치") {
                LabeledContent("Engine") {
                    Text(model.paths.engineRoot.path)
                        .lineLimit(2)
                        .textSelection(.enabled)
                }
                LabeledContent("Payload") {
                    Text(model.payload?.version ?? "unknown")
                }
                Button("엔진 다시 설치") {
                    Task {
                        await model.installEngine(force: true)
                        await model.refresh()
                    }
                }
            }

            Section("로그인") {
                configText("KAIST ID", .ssoLoginID)
                configToggle("로그인 보조", .loginAssistEnabled)
                Picker("보조 모드", selection: binding(.loginAssistMode, defaultValue: "manual-digits")) {
                    Text("manual-digits").tag("manual-digits")
                    Text("kaikey-auto").tag("kaikey-auto")
                }
                configToggle("비대화 실행 허용", .loginAssistAllowNoninteractive)
            }

            Section("실행") {
                configToggle("자동 실행", .autoSyncEnabled)
                configText("동기화 주기(초)", .syncIntervalSeconds)
                configText("Idle 조건(초)", .minIdleSeconds)
                configToggle("사용자 활동 시 자동실행 중단", .syncAbortOnUserActivity)
                configText("중단 idle 기준(초)", .syncActiveAbortIdleSeconds)
                configToggle("Safari 백그라운드 창 사용", .safariBackgroundWindowEnabled)
                Picker("Sync mode", selection: binding(.syncMode, defaultValue: "auto")) {
                    Text("auto").tag("auto")
                    Text("quick").tag("quick")
                    Text("full").tag("full")
                }
                Picker("File mode", selection: binding(.fileRefreshMode, defaultValue: "auto")) {
                    Text("auto").tag("auto")
                    Text("quick").tag("quick")
                    Text("full").tag("full")
                }
            }

            Section("파일") {
                configToggle("새 다운로드 staging 유지", .fileKeepFreshDownloads)
                configToggle("주차/source 폴더 사용", .fileWeeklyFoldersEnabled)
                configToggle("강제 재다운로드", .fileForceDownload)
                configToggle("다운로드 archive 보존", .filePreserveDownloadArchive)
                configText("새 파일 inbox", .fileNewFilesRoot)
                configText("Quarantine root", .fileQuarantineRoot)
            }

            Section("공지") {
                configText("공지 메모", .noticeNoteName)
                configText("확인한 공지 메모", .noticeArchiveNoteName)
                configToggle("최상위 섹션 접기", .noticeCollapseSections)
                configToggle("과목 접기", .noticeCollapseCourses)
                configToggle("공지 제목 접기", .noticeCollapseItems)
                configToggle("공지 제목 heading", .noticeStyleItemsAsHeadings)
            }
        }
        .formStyle(.grouped)
        .padding()
    }

    private func configText(_ title: String, _ key: EnvKnownKey) -> some View {
        TextField(title, text: binding(key))
    }

    private func configToggle(_ title: String, _ key: EnvKnownKey) -> some View {
        Toggle(title, isOn: boolBinding(key))
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

    private func boolBinding(_ key: EnvKnownKey) -> Binding<Bool> {
        Binding(
            get: {
                model.boolConfigValue(key)
            },
            set: { value in
                model.setBoolConfigValue(value, for: key)
            }
        )
    }
}
