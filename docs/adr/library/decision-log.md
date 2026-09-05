# Decision Log: library

이 문서는 library 카테고리의 주요 결정 변경 이력이다. ADR 본문은 현재 상태만 서술하고,
주요 전환은 최신 순으로 남긴다.

## 2026-09-05 — 프로젝트 revision과 호환성 제외 경계를 추가

- **Current ADR**: [local-project-library](./0001-local-project-library.md)
- **Change type**: architecture
- **What**: 단일 로컬 인덱스와 캡처 자산 저장에서, 영상·편집 상태의 원자 저장과 UI·MCP
  동시 편집 revision 검증을 포함하는 프로젝트 저장 계약으로 확장했다. 기존 파일은 보존하지만
  새 모델의 읽기·변환·내보내기 호환성은 제공하지 않는다.
- **Why**: 외부 MCP 편집이 사람의 최신 변경을 덮어쓰지 않고, 새 Click Cue 모델이 불확실한
  기존 데이터를 자동 변환하지 않아야 한다.

<!-- adr-writer:rules-version 0.8.13 — seeded by /adr-new. `adr-structure-lint` warns when this trails the installed plugin; refresh with /adr-new (it re-seeds a stale doc set). Keep this line on re-seed. -->
