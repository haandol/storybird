# ADR 0003: 안정적인 서명 신원과 최소 권한을 사용한다

Date: 2026-09-02

## Status

Accepted (2026-09-02)

## Context

macOS는 화면 기록과 입력 모니터링 권한을 앱 번들 신원에 연결한다. ad-hoc 서명은 지정
요구사항이 바이너리 CDHash가 되어 재빌드마다 다른 앱으로 인식될 수 있다. 또한 사전 권한 API는
설정 화면과 실제 캡처 가능 상태가 순간적으로 어긋날 수 있다.

## Decision Drivers

- 개발 빌드에서도 권한 승인이 재빌드 사이에 유지돼야 한다.
- Storybird는 화면과 마우스 클릭만 필요하며 키보드 입력은 필요 없다.
- stale 사전 검사 때문에 실제로 가능한 캡처를 차단하면 안 된다.
- 권한 실패는 사용자가 고칠 수 있는 설정 위치와 이유를 보여야 한다.

## Decision

빌드 하네스는 Developer ID 또는 Apple Development 인증서를 우선 사용하고, 없을 때만
ad-hoc으로 후퇴하며 권한 반복 가능성을 경고한다. 번들 ID는 `com.storybird.app`으로
고정한다. 화면 접근은 실제 ScreenCaptureKit 호출을 먼저 시도하고, 실패한 뒤에만 권한 문제로
분류한다. Input Monitoring은 mouse-down 관찰에만 사용한다.

### Requirement Contract

- 실제 인증서가 있으면 `TeamIdentifier`가 있는 서명으로 빌드한다.
- ad-hoc fallback은 허용하지만 기능적으로 동등하다고 보고하지 않는다.
- Screen Recording과 Input Monitoring 외의 캡처 관련 권한을 추가하지 않는다.
- 키보드 이벤트를 등록하거나 저장하지 않는다.
- Storybird UI는 권한 변경을 직접 수행하지 않고 시스템 설정으로 안내한다.

## 대안 검토

### 항상 ad-hoc 서명

인증서 준비가 필요 없지만 재빌드마다 TCC 승인이 끊길 수 있어 일상 개발 자체가 불안정하다.

### 권한 사전 검사 결과만 신뢰

빠르게 실패할 수 있지만 설정 토글과 실제 API 상태가 어긋난 사례에서 작동 가능한 캡처를
차단했다. 실제 API 결과를 권위로 두는 쪽을 채택했다.

### 키보드까지 수집하는 접근성 권한 사용

입력 문맥을 더 많이 알 수 있지만 제품 요구에 없고 민감도와 공격 표면만 키운다.

## Consequences

- 같은 인증서와 번들 ID를 쓰는 빌드는 권한 신원이 안정적이다.
- 인증서가 없는 기여자는 반복 승인을 경험할 수 있다.
- OpenLane에서 번들 ID가 바뀌는 최초 전환에는 한 번 새 승인이 필요하다.

## Related

- [썸네일 갤러리에서 녹화 소스를 선택한다](./0001-thumbnail-source-selection.md)
