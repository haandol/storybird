# Decision Log: timeline-editing

이 문서는 timeline-editing 카테고리의 주요 결정 변경 이력이다. 각 ADR 본문은 현재
상태만 서술하고, 주요 전환의 시간축은 여기에 역순으로 쌓는다.

## 2026-09-10 — 분리 제작과 오디오 레이어 편집

- **Current ADR**: [0001-non-destructive-clip-timeline](./0001-non-destructive-clip-timeline.md)
- **Change type**: requirement rule change
- **What**: 순차 내레이션 중심 제작 → 독립 오디오 자산과 중첩 레이어를 사용하는 제작.
- **Why**: 대본에서 TTS를 생성하는 에이전트가 음성 길이에 맞춰 영상과 여러 레이어를 완성해야 한다.

## 2026-09-10 — 장면 연결 음성과 자막

- **현재 ADR**: [0001-non-destructive-clip-timeline](./0001-non-destructive-clip-timeline.md)
- **변경 유형**: 시간 연결 규칙
- **무엇이**: 프로젝트 고정 시각에 선택적 장면 연결을 추가한다.
- **왜**: 클립을 다시 편집해도 같은 장면에서 설명을 시작하면서 발화 길이와 기존 고정 시각을 보존한다.

## 2026-09-08 — 가져온 영상의 기본 음성을 클립 시간축에 포함

- **현재 ADR**: [non-destructive-clip-timeline](./0001-non-destructive-clip-timeline.md)
- **변경 유형**: 요구사항 규칙 변경
- **무엇이**: 무음 영상 전용 타임라인에서, 읽을 수 있는 기본 음성이 있는 영상 클립은 같은
  원본 범위·순서·속도 변환을 사용하고 정지 화면과 전체 화면 카드 구간은 무음인 타임라인으로
  확장했다.
- **왜**: 사용자가 말하며 만든 제품 소개 영상을 가져와도 설명 음성이 화면 장면과 함께
  편집돼야 한다.
## 2026-09-08 — 프로젝트 소유 문장별 내레이션 레이어 추가

- **현재 ADR**: [non-destructive-clip-timeline](./0001-non-destructive-clip-timeline.md)
- **변경 유형**: 요구사항 규칙 변경
- **무엇이**: 영상과 기본 음성 시간축에 서로 겹치지 않는 프로젝트 소유 문장별 내레이션
  레이어와 원자적 재생성 규칙을 추가했다.
- **왜**: 원고 한 문장만 같은 목소리로 다시 생성하고 영상 타임라인에서 편집해야 한다.
