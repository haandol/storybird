# Decision Log: application-settings

## 2026-09-29 — 설정과 MCP에서 명시적으로 버전을 확인한다

- **현재 ADR**: [native-settings-and-shortcuts](./0001-native-settings-and-shortcuts.md)
- **변경 유형**: 앱 정보, 외부 통신 경계와 조회 상태
- **무엇이**: 번들 버전·빌드 표시와 UI/MCP의 수동 GitHub 릴리즈 조회를 추가한다.
- **왜**: 사용자가 새 버전을 확인할 수 있어야 하며 로컬 작업 중 자동 통신은 필요하지 않다.

## 2026-09-09 — 일반 설정에서 프로젝트 폴더를 선택한다

- **현재 ADR**: [native-settings-and-shortcuts](./0001-native-settings-and-shortcuts.md)
- **변경 유형**: 지속 설정과 사용자 동작
- **무엇이**: 저장 경로 표시를 폴더 선택·Finder 열기·기본 위치 복원으로 확장했다.
- **왜**: 사용자가 프로젝트 저장 공간을 선택하고, 작업 중 변경 금지와 기존 파일 보존을
  설정 화면에서 이해할 수 있어야 한다.
