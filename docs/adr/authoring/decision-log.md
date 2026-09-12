# Decision Log: authoring

이 문서는 authoring 카테고리의 주요 결정 변경 이력이다. ADR 본문은 현재 상태만
서술하고, 주요 전환의 시간축은 여기에 최신 순으로 남긴다.

## 2026-09-12 — 트랙패드 핀치로 타임라인 확대

- **Current ADR**: [timeline-overlay-editor](./0001-timeline-overlay-editor.md)
- **Change type**: requirement rule change
- **What**: 버튼·슬라이더·Option 스크롤 확대에 수정자 없는 두 손가락 핀치를 추가한다.
- **Why**: 트랙패드에서 같은 포인터 기준 확대를 직접 사용하면서 프로젝트와 재생 시각을 유지한다.

## 2026-09-12 — 편집기 재생 키와 정밀 타임라인 탐색

- **Current ADR**: [timeline-overlay-editor](./0001-timeline-overlay-editor.md)
- **Change type**: requirement rule change
- **What**: 버튼 중심 재생과 고정 배율 → 편집 작업 영역의 Space 재생·정지, 일시적인 초 표시, 배율 조절·전체 맞춤·Option 스크롤 확대.
- **Why**: 포커스가 남은 다른 버튼의 실행을 막고 현재 시각과 짧은 시간 구간을 정확히 찾도록 한다.

## 2026-09-10 — 기본 빈 영상 화면과 경계 드래그

- **Current ADR**: [timeline-overlay-editor](./0001-timeline-overlay-editor.md)
- **Change type**: requirement rule change
- **What**: 기본 숨김 제안을 빈 영상 영역과 타임라인을 함께 표시하는 초기 상태로 바꾼다. 빈 영역에서 실제 미리보기를 켜고, 빈 영역이나 실제 영상 모두 숨길 수 있다. 영상·타임라인 경계를 드래그해 높이를 조절하며 숨김 상태의 타임라인 전체 높이 사용은 유지한다.
- **Why**: 처음부터 영상 영역의 위치를 파악하고 작업에 맞게 영상과 레이어 사이의 공간을 직접 배분해야 한다. 보기 조절은 프로젝트 수정이나 실행 취소 기록을 만들지 않는다.

## 2026-09-10 — 미리보기 토글과 타임라인 높이 확장

- **Current ADR**: [timeline-overlay-editor](./0001-timeline-overlay-editor.md)
- **Change type**: requirement rule change
- **What**: 영상 미리보기의 기본 숨김과 반복 가능한 표시·숨김 토글을 정의한다. 숨김 상태에서는 재생 컨트롤과 열려 있는 편집 패널을 제외한 하단의 남은 높이 전체를 타임라인이 사용한다.
- **Why**: 영상을 확인한 뒤 다시 레이어 편집 공간을 확보하고, 넓은 창과 좁은 창 모두에서 더 많은 레이어를 볼 수 있어야 한다.

## 2026-09-10 — 타임라인에서 오디오를 직접 배치하고 편집한다

- **Current ADR**: [timeline-overlay-editor](./0001-timeline-overlay-editor.md)
- **Change type**: requirement rule change
- **What**: 별도 양식 중심 오디오 편집에서 제작 패널, 드래그 배치, 가장자리 트림, 선택 도구막대, 음량·페이드 조절과 블록 원고 편집으로 변경한다.
- **Why**: 영상과 파형을 보며 위치와 사용 구간을 조절하고 각 조작을 실행 취소 한 번으로 복원한다.

## 2026-09-10 — 자동 행 정리와 종류별 펼치기

- **Current ADR**: [timeline-overlay-editor](./0001-timeline-overlay-editor.md)
- **Change type**: requirement rule change
- **What**: 모든 레이어의 개별 행 표시를 기본 자동 정리와 종류별 개별 행 토글로 바꾼다.
- **Why**: 순차 자막은 같은 행에 모으고 겹치는 항목도 각각 선택하면서 필요한 경우 모두 펼쳐 볼 수 있어야 한다.

## 2026-09-10 — 레이어별 행과 드래그 타이밍 편집

- **Current ADR**: [timeline-overlay-editor](./0001-timeline-overlay-editor.md)
- **Change type**: requirement rule change
- **What**: 종류별로 겹쳐 표시하던 레이어를 각각 한 행에 표시하고 세로 스크롤과 좌우 드래그 이동을 제공한다.
- **Why**: 겹치는 항목도 직접 선택하고 길이와 장면 연결을 보존하면서 타이밍을 조정해야 한다.

## 2026-09-10 — 분리 제작과 오디오 레이어 편집

- **Current ADR**: [0001-timeline-overlay-editor](./0001-timeline-overlay-editor.md)
- **Change type**: requirement rule change
- **What**: 순차 내레이션 중심 제작 → 독립 오디오 자산과 중첩 레이어를 사용하는 제작.
- **Why**: 대본에서 TTS를 생성하는 에이전트가 음성 길이에 맞춰 영상과 여러 레이어를 완성해야 한다.

## 2026-09-10 — 장면 연결 독립 자막

- **현재 ADR**: [0001-timeline-overlay-editor](./0001-timeline-overlay-editor.md)
- **변경 유형**: 시간 연결 규칙
- **무엇이**: 프로젝트 고정 시각에 선택적 장면 연결을 추가한다.
- **왜**: 자막 시작점을 원본 장면과 연결하고 고정 시각을 선택할 수 있게 한다.

## 2026-09-05 — 클릭 안내를 완성 상태가 있는 Click Cue로 묶음

- **현재 ADR**: [timeline-overlay-editor](./0001-timeline-overlay-editor.md)
- **변경 유형**: 아키텍처
- **무엇이**: 선택적인 클릭 캡션과 독립 자막을, 클릭 표시·설명·자막이 같은 클릭 시점을
  포함하는 Click Cue 그룹과 별도 구간 자막 모델로 정리했다. 기존 프로젝트 자동 변환은
  제공하지 않는다.
- **왜**: 유지할 모든 클릭의 설명과 자막 완결성을 검증하고 UI·MCP·MP4가 같은 합성 결과를
  사용해야 한다.

## 2026-09-05 — 분기형 화면 편집기를 영상 타임라인 편집기로 전환

- **현재 ADR**: [timeline-overlay-editor](./0001-timeline-overlay-editor.md)
- **변경 유형**: 아키텍처
- **무엇이**: 화면과 대상 핫스팟을 편집하던 모델을, 원본 영상과 시간 기반 클릭·자막 레이어를
  편집하는 모델로 바꿨다.
- **왜**: 연속 영상 위에서 클릭 강조와 자막의 시각·위치를 직접 확인하고 수정해야 한다.
- **무효가 된 것**: 화면 분기와 인터랙티브 플레이어가 핵심 편집 계약이라는 전제.

## 2026-09-05 — 인증된 로컬 제어에 편집·미리보기 기능 노출

- **현재 ADR**: [timeline-overlay-editor](./0001-timeline-overlay-editor.md)
- **변경 유형**: 아키텍처
- **무엇이**: 앱 UI에서만 가능하던 프로젝트 조회·텍스트·핫스팟 편집과 미리보기를, 앱이
  검증하고 저장하는 인증된 로컬 control gateway에도 노출했다.
- **왜**: 무권한 MCP companion이 라이브러리를 직접 수정하지 않으면서 Storybird 내부 기능을
  자동화에 사용할 수 있어야 한다.

## 2026-09-02 — 클릭포인트 캡션과 화면 자막 오버레이 추가

- **현재 ADR**: [timeline-overlay-editor](./0001-timeline-overlay-editor.md)
- **변경 유형**: 아키텍처
- **무엇이**: 화면 밖 하단 캡션만 제공하던 모델을 클릭포인트 주변 캡션과 상단·하단 화면
  자막이 색상·투명도 스타일을 공유하는 오버레이 계약으로 확장했다.
- **왜**: 사용자가 클릭 맥락과 화면 전체 안내를 캡처 위에서 직접 전달하고, 서로 다른 캡처
  배경에서도 가독성을 조정할 수 있어야 한다.

## 2026-09-02 — 좁은 창에서 편집 열을 메뉴와 시트로 전환

- **현재 ADR**: [timeline-overlay-editor](./0001-timeline-overlay-editor.md)
- **변경 유형**: UX 아키텍처
- **무엇이**: 프로젝트 사이드바와 화면 목록·캔버스·인스펙터를 모든 폭에서 고정 표시한다
  → 좁은 창에서는 프로젝트 사이드바를 자동으로 접고 화면 선택을 메뉴로, 인스펙터를 시트로
  전환한다.
- **왜**: 고정 최소 폭의 합이 작은 디스플레이와 축소된 창 너비를 넘으면서 우측 인스펙터와
  사이드바 일부가 화면 밖으로 잘려 편집 기능에 접근할 수 없었다.
