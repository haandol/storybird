# ADR 0001: 프로젝트 라이브러리를 기기 안에 원자적으로 저장한다

Date: 2026-09-02

## Status

Accepted (2026-09-02)

## Context

캡처 화면에는 고객 데이터와 자격 증명 같은 민감한 정보가 포함될 수 있다. 초기 제품에는 계정,
동기화, 협업 요구가 없으며 녹화 중 장애가 프로젝트 인덱스와 자산 참조를 깨뜨리면 복구가 어렵다.
이름 변경으로 기존 OpenLane 라이브러리도 보존해야 한다.

## Decision Drivers

- 캡처와 분석 이벤트가 외부로 전송되면 안 된다.
- 프로젝트 인덱스는 부분 쓰기로 손상되면 안 된다.
- 존재하지 않는 자산을 프로젝트가 참조하면 안 된다.
- 기존 OpenLane 데이터와 새 Storybird 데이터 중 어느 것도 덮어쓰면 안 된다.

## Decision

Storybird는 Application Support 아래 JSON 인덱스와 프로젝트별 PNG 자산을 저장한다. 자산을
먼저 원자적으로 쓴 뒤 인덱스를 원자 교체한다. Storybird 루트가 없고 OpenLane 루트가 있을 때만
전체 라이브러리를 복사하며 원본은 남긴다. 두 루트가 이미 있으면 Storybird를 권위로 둔다.

### Requirement Contract

- 기본 루트는 `~/Library/Application Support/Storybird`다.
- 라이브러리 JSON은 atomic write를 사용한다.
- 캡처 자산 저장 실패 시 프로젝트에 단계를 추가하지 않는다.
- legacy 마이그레이션은 copy-only이며 OpenLane 데이터를 삭제하지 않는다.
- Storybird 라이브러리가 존재하면 legacy 데이터로 덮어쓰지 않는다.

## 대안 검토

### SQLite에 인덱스와 이미지 blob을 모두 저장

트랜잭션은 강하지만 초기 데이터 모델에 비해 복잡하고 정적 내보내기와 수동 진단이 어려워진다.

### 클라우드 저장을 기본으로 사용

공유와 백업은 쉬워지지만 계정·보안·개인정보·운영 인프라를 요구하고 local-first 경계를 깨뜨린다.

### OpenLane 폴더를 Storybird로 이동

중복 저장은 피하지만 이름 변경 중 실패하면 유일한 원본을 잃고 이전 앱으로 돌아갈 수 없다.

## Consequences

- 사용자가 프로젝트 폴더를 백업하고 진단하기 쉽다.
- 여러 프로세스의 동시 편집은 지원하지 않는다.
- 이름 변경 직후에는 legacy와 Storybird 복사본이 함께 존재할 수 있다.
