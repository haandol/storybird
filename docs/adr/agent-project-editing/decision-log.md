# Decision Log: agent-project-editing

이 문서는 agent-project-editing 카테고리의 주요 결정 변경 이력이다.

## 2026-09-10 — 분리 제작과 오디오 레이어 편집

- **Current ADR**: [0001-versioned-mcp-project-editing](./0001-versioned-mcp-project-editing.md)
- **Change type**: requirement rule change
- **What**: 순차 내레이션 중심 제작 → 독립 오디오 자산과 중첩 레이어를 사용하는 제작.
- **Why**: 대본에서 TTS를 생성하는 에이전트가 음성 길이에 맞춰 영상과 여러 레이어를 완성해야 한다.

## 2026-09-10 — 텍스트 요청용 편집과 음성 초안·독립 복제

- **현재 ADR**: [versioned-mcp-project-editing](./0001-versioned-mcp-project-editing.md)
- **변경 유형**: 자동 제작 범위와 데이터 수명
- **무엇이**: 기존 편집 경계에 시작 장면 연결, 재사용 가능한 음성 초안과 독립 프로젝트 복제를 포함한다.
- **왜**: 사용자의 텍스트 요청을 문장·장면별 변경으로 반영하고, 생성과 배치의 실패를 분리하면서 기존 프로젝트를 보존한다.

## 2026-09-08 — 기존 음성 프로필을 사용하는 내레이션 자동화 추가

- **현재 ADR**: [versioned-mcp-project-editing](./0001-versioned-mcp-project-editing.md)
- **변경 유형**: 권한 및 요구사항 규칙 변경
- **무엇이**: MCP 편집 범위에 기존 프로필 조회와 문장별 내레이션 생성·수정·삭제를 추가하고,
  음성 등록·마이크·모델 다운로드·프로필 삭제는 네이티브 사용자 동작으로 유지했다.
- **왜**: 에이전트가 서비스 데모를 완성하면서 민감한 음성 권한은 사용자에게 남겨야 한다.
