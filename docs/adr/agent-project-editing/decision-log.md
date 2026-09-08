# Decision Log: agent-project-editing

이 문서는 agent-project-editing 카테고리의 주요 결정 변경 이력이다.

## 2026-09-08 — 기존 음성 프로필을 사용하는 내레이션 자동화 추가

- **현재 ADR**: [versioned-mcp-project-editing](./0001-versioned-mcp-project-editing.md)
- **변경 유형**: 권한 및 요구사항 규칙 변경
- **무엇이**: MCP 편집 범위에 기존 프로필 조회와 문장별 내레이션 생성·수정·삭제를 추가하고,
  음성 등록·마이크·모델 다운로드·프로필 삭제는 네이티브 사용자 동작으로 유지했다.
- **왜**: 에이전트가 서비스 데모를 완성하면서 민감한 음성 권한은 사용자에게 남겨야 한다.
