# KLMS Sync Windows

Windows companion app for the KLMS Sync server relay.

이 앱은 KLMS를 직접 긁지 않는다. 서버 릴레이에 저장된 sanitized 상태와 항목 목록을 읽고, 실행 요청과 항목 처리 요청만 만든다. 실제 KLMS 동기화, Notes, Calendar, Reminders 반영은 Mac 앱이 처리한다.

## 기능

- 서버 릴레이 URL/클라이언트 토큰 저장
- Mac 앱에서 복사한 Cloudflare 릴레이 연결 정보를 클립보드에서 바로 읽기
- 대시보드 카운트 확인
- 과제, 시험, 공지, 파일 목록 검색/정렬
- 숨김/무시 항목은 전체에서 제외하고 보관함에서 별도 확인
- 파일 목록은 KLMS 등록 시각 기준 최신 순, 서버 갱신 순, 과목/제목/종류 순 정렬
- 파일 목록 기본 정렬은 KLMS 등록 시각 기준 최신 순
- 파일 경로는 Mac의 기본 정책과 맞춰 과목/주차/출처 폴더 구조를 전제로 표시
- 캘린더 생성/수정/삭제 요약 확인
- 항목 상세 확인
- 공지 읽음/중요 ON/OFF 토글
- 과제 완료/숨김, 시험 후보 확정/무시, 파일 숨김 요청
- 파일 열기 요청: Mac이 로컬 `course_files` 원본을 임시 업로드하고 만료 링크를 제공
- 전체/과제/공지/파일/진단 원격 실행 요청
- 최근 요청 상태 확인
- 로그 요약 카드 확인: 인증, 실패, 단계 완료, 파일 변경량, 다운로드 요약

## 개발 실행

Windows에서:

```powershell
cd apps\KLMSyncWindows
npm install
npm start
```

설치 파일 빌드:

```powershell
npm run dist:win
```

## 연결

1. Mac에서 KLMS Sync 앱을 켠다.
2. 서버 릴레이를 켜고 연결 정보를 복사한다.
3. Windows 앱에서 `클립보드`, `저장 후 연결 확인` 순서로 누른다.
4. 연결됨 상태가 뜨면 대시보드 카드나 항목 목록을 눌러 상세를 확인한다.

HTTP는 `localhost`, 사설 IP, `.local` 주소에서만 허용한다. 외부에서 쓰는 공개 주소는 HTTPS여야 한다.

같은 네트워크 밖에서 쓰려면 `deploy/cloudflare-worker`의 Cloudflare Workers + D1 릴레이를 띄운 뒤 Windows/iPhone에는 클라이언트 토큰을, Mac 앱에는 Mac worker 토큰을 넣는다. Windows 앱은 Mac에 직접 접속하지 않고 서버 DB에 요청을 남기며, Mac 앱이 polling해서 실제 동기화를 실행한다.

## 보안

- 클라이언트 토큰은 Electron main process에서만 읽고 renderer에는 저장하지 않는다.
- Windows에서는 Electron `safeStorage`를 통해 OS 암호화 저장소를 사용하고, 암호화 저장소가 없으면 토큰을 저장하지 않는다.
- 서버에는 원본 로그, KLMS URL, `config.env`, Kaikey state, 절대 파일 경로를 올리지 않는다.
- 파일 원본은 사용자가 파일 열기를 요청한 경우에만 임시 업로드되며, 링크 만료 후 서버 기록과 임시 파일을 정리한다.

## 구현 가이드

Windows 앱을 Mac/iPhone/iPad UI와 맞춰 고도화할 때는 [docs/windows-implementation-guide.md](../../docs/windows-implementation-guide.md)를 기준으로 작업한다. 실제 서버 URL, 토큰, 개인 경로는 코드나 문서 기본값에 넣지 않는다.
