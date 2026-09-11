# Decision Log: voice-narration

This document is the **major decision-change history** of the voice-narration category.
Each ADR body describes only the current state, while the timeline of "what changed and
why" accumulates here, newest first. Git preserves the individual diffs.

## 2026-09-11 — 두 8비트 모델과 무인 준비를 지원한다

- **Current ADR**: [local-cloned-voice-narration](./0001-local-cloned-voice-narration.md)
- **Change type**: requirement rule change
- **What**: 1.7B 고정·네이티브 다운로드 승인 → 1.7B/0.6B Base 8비트 선택과 UI/MCP의 추가 승인 없는 모델 준비.
- **Why**: 에이전트가 사용할 모델을 확인하고 준비부터 음성 생성까지 무인으로 수행해야 한다.

## 2026-09-11 — 로컬 미디어 경로 직접 가져오기

- **Current ADR**: [0001-local-cloned-voice-narration](./0001-local-cloned-voice-narration.md)
- **Change type**: requirement rule change
- **What**: 파일별 네이티브 선택 → 인증된 MCP 연결의 로컬 미디어 경로 직접 가져오기와 중복 없는 작업 결과 보존.
- **Why**: 에이전트 제작에서 파일마다 사용자 클릭을 요구하지 않는다.

## 2026-09-11 — 음성 참조 대본을 인사로 시작하는 약 20초 발표로 구성한다

- **Current ADR**: [local-cloned-voice-narration](./0001-local-cloned-voice-narration.md)
- **Change type**: requirement rule change
- **What**: 한국어·영어의 `10초...15초` 대본을 각각 해당 언어의 인사로 시작하는 약 `20초`
  발표 대본으로 바꾼다. 한국어에는 영어 기능명을 자연스럽게 섞고, 두 언어 모두 질문·강조·쉼을
  포함한다. 최소 녹음은 `10초`를 유지한다.
- **Why**: 실제 발표에서 쓰는 혼합 발화와 다양한 억양, 충분한 설명 분량을 참조 음성에 담는다.

## 2026-09-10 — 생성한 음성 프로필의 표시 이름을 변경한다

- **Current ADR**: [local-cloned-voice-narration](./0001-local-cloned-voice-narration.md)
- **Change type**: requirement rule change
- **What**: 생성 뒤 이름을 수정할 수 없는 프로필에 네이티브 설정의 이름 변경을 제공한다.
- **Why**: 참조 음성과 기존 내레이션을 보존하면서 사용자가 프로필 표시 이름을 관리해야 한다.

## 2026-09-10 — 분리 제작과 오디오 레이어 편집

- **Current ADR**: [0001-local-cloned-voice-narration](./0001-local-cloned-voice-narration.md)
- **Change type**: requirement rule change
- **What**: 순차 내레이션 중심 제작 → 독립 오디오 자산과 중첩 레이어를 사용하는 제작.
- **Why**: 대본에서 TTS를 생성하는 에이전트가 음성 길이에 맞춰 영상과 여러 레이어를 완성해야 한다.

## 2026-09-10 — 프로필 목록과 생성 모달을 분리한다

- **현재 ADR**: [local-cloned-voice-narration](./0001-local-cloned-voice-narration.md)
- **변경 유형**: 생성·취소 수명과 입력 가시성
- **무엇이**: 설정의 인라인 생성 양식을 목록 아래 진입점과 별도 생성 모달로 바꾼다. 이름·언어·동의와 입력 방식을 모달에서 설정하고 저장 성공 또는 취소 시 닫는다.
- **왜**: 지속 설정과 일회성 녹음 작업의 혼란을 줄이고, 저장 실패와 취소의 결과를 명확하게 보여 준다.

## 2026-09-10 — 언어 선택과 재사용 가능한 음성 초안

- **현재 ADR**: [local-cloned-voice-narration](./0001-local-cloned-voice-narration.md)
- **변경 유형**: 합성·배치 수명과 언어 선택
- **무엇이**: 한국어·영어를 선택하고 합성 완료 음성을 초안으로 보관한 뒤 고정 시각 또는 장면에 배치한다.
- **왜**: 문장 길이를 확인한 뒤 화면을 편집하고, 실패한 배치를 재합성 없이 다시 시도한다.

## 2026-09-09 — 공유 음성 관리와 프로젝트 내레이션 작성을 분리한다

- **Current ADR**: [local-cloned-voice-narration](./0001-local-cloned-voice-narration.md)
- **Change type**: requirement rule change | fallback policy
- **What**: 모델 준비, 프로필 등록·삭제와 안내 녹음용 마이크 선택을 설정으로 옮기고,
  프로젝트는 기존 프로필을 사용한 내레이션 작성만 담당한다. 특정 마이크 선택은 유지하되
  장치가 없으면 시스템 기본 입력으로 대체한다.
- **Why**: 여러 프로젝트가 공유하는 민감 음성 자산과 현재 프로젝트 편집을 분리하고, 사용자가
  원하는 입력 장치를 지속적으로 선택하면서 장치 분리 때문에 프로필 녹음 경로를 잃지 않게
  해야 한다.

## 2026-09-08 — 안내 녹음의 길이·가시성과 선행 동의를 강화한다

- **Current ADR**: [local-cloned-voice-narration](./0001-local-cloned-voice-narration.md)
- **Change type**: requirement value change | requirement rule change
- **What**: 마이크 프로필의 최소 녹음 길이를 `3초` → `10초`로 바꾸고, 억양 표본 대본과
  녹음 상태·경과 시간·입력 레벨 표시를 필수 경험으로 추가했다. 음성 사용 권한 확인 전에는
  파일 선택과 마이크 녹음을 시작할 수 없게 했다.
- **Why**: 짧고 상태가 불분명한 녹음은 화자 억양을 충분히 담기 어렵고 사용자가 실제 녹음
  진행 여부와 최소 길이 충족을 판단하기 어렵다. 민감한 음성 입력은 사용 권한 확인보다 먼저
  접근하면 안 된다.

<!-- adr-writer:rules-version 0.8.13 — seeded by /adr-new. `adr-structure-lint` warns when this trails the installed plugin; refresh with /adr-new (it re-seeds a stale doc set). Keep this line on re-seed. -->
