구형 호환 wrapper와 수동 디버깅 보조 도구만 남겨 두는 디렉터리입니다.

현재는 `legacy/` 루트에 수동 점검용 보조 도구와 자동 동기화 경로에서 빠진 one-off 도구만 유지합니다.

- `extract_document_text.swift`, `download_klms_files_xhr_simple.js`
  - 수동 점검용 보조 도구
- `download_klms_media_via_safari.js`, `export_panopto_transcripts.js`, `fetch_active_safari_page.js`
  - 현재 기본 KLMS sync에서 호출하지 않는 one-off 수집/디버깅 도구

정리 원칙:

- 루트에는 중복 실험본이나 `* 2` 임시 사본을 남기지 않음
- 운영 경로에서 직접 쓰지 않는 구형 실험 스크립트는 `src/`에 두지 않음
- 새 기능은 `tools/` 또는 메인 실행 경로에 추가
