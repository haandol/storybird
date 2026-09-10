# Decision Log: library

이 문서는 library 카테고리의 주요 결정 변경 이력이다. ADR 본문은 현재 상태만 서술하고,
주요 전환은 최신 순으로 남긴다.

## 2026-09-10 — 기본 프로젝트 위치를 문서 폴더로 지정

- **현재 ADR**: [local-project-library](./0001-local-project-library.md)
- **변경 유형**: 저장 위치 계약
- **무엇이**: 기본 프로젝트 위치와 기본 위치 복원을 Application Support에서
  `~/Documents/Storybird`로 변경한다. 사용자 지정 폴더와 기존 파일을 보존하며 공유 음성
  자산과 MCP 연결은 Application Support에 유지한다.
- **왜**: Scribird처럼 Finder에서 프로젝트를 쉽게 찾고 백업할 수 있어야 한다.

## 2026-09-10 — 독립 복제와 음성 초안 소유권

- **현재 ADR**: [local-project-library](./0001-local-project-library.md)
- **변경 유형**: 데이터 수명과 저장 규칙
- **무엇이**: 영상·배치된 음성을 독립 프로젝트로 복사하고, 미배치 합성 초안을 편집 revision과 분리해 보존한다.
- **왜**: 언어별 버전과 배치 실패 후 음성 재사용이 원본 및 기존 편집을 훼손하지 않아야 한다.

## 2026-09-09 — 프로젝트 폴더 선택과 공유 음성 저장 분리

- **현재 ADR**: [local-project-library](./0001-local-project-library.md)
- **변경 유형**: 저장 경계와 전환 규칙
- **무엇이**: 고정 프로젝트 루트에서 사용자 선택 라이브러리로 전환한다. 기존 파일은
  이동하지 않고 공유 음성 프로필·모델은 기본 위치를 유지한다.
- **왜**: 저장 공간을 선택하면서 진행 중인 작업, 이전 프로젝트와 공유 음성 환경을 보존한다.

## 2026-09-08 — 음성 프로필과 프로젝트 내레이션 자산 수명 분리

- **현재 ADR**: [local-project-library](./0001-local-project-library.md)
- **변경 유형**: 데이터 수명 규칙 변경
- **무엇이**: 로컬 음성 프로필 참조 자산과 프로젝트 소유 생성 내레이션을 별도 수명으로
  저장하고, 프로필 삭제가 기존 프로젝트 음성을 제거하지 않게 했다.
- **왜**: 민감한 참조 음성을 삭제하면서 완성된 프로젝트와 내보내기 결과를 보존해야 한다.

## 2026-09-05 — 프로젝트 revision과 호환성 제외 경계를 추가

- **Current ADR**: [local-project-library](./0001-local-project-library.md)
- **Change type**: architecture
- **What**: 단일 로컬 인덱스와 캡처 자산 저장에서, 영상·편집 상태의 원자 저장과 UI·MCP
  동시 편집 revision 검증을 포함하는 프로젝트 저장 계약으로 확장했다. 기존 파일은 보존하지만
  새 모델의 읽기·변환·내보내기 호환성은 제공하지 않는다.
- **Why**: 외부 MCP 편집이 사람의 최신 변경을 덮어쓰지 않고, 새 Click Cue 모델이 불확실한
  기존 데이터를 자동 변환하지 않아야 한다.

<!-- adr-writer:rules-version 0.8.13 — seeded by /adr-new. `adr-structure-lint` warns when this trails the installed plugin; refresh with /adr-new (it re-seeds a stale doc set). Keep this line on re-seed. -->
