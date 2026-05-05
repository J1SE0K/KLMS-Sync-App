구형 호환 wrapper와 수동 디버깅 보조 도구만 남겨 두는 디렉터리입니다.

현재는 `legacy/` 루트에 수동 점검용 보조 도구만 유지합니다.

- `extract_document_text.swift`, `download_klms_files_xhr_simple.js`
  - 수동 점검용 보조 도구

정리 원칙:

- 루트에는 중복 실험본이나 `* 2` 임시 사본을 남기지 않음
- 운영 경로에서 직접 쓰지 않는 구형 실험 스크립트는 보관하지 않음
- 새 기능은 `tools/` 또는 메인 실행 경로에 추가
