# Decision Log: voice-narration

This document is the **major decision-change history** of the voice-narration category.
Each ADR body describes only the current state, while the timeline of "what changed and
why" accumulates here, newest first. Git preserves the individual diffs.

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
