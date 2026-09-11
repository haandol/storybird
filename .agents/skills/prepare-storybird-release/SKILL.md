---
name: prepare-storybird-release
description: Prepare Storybird releases, write release notes, check readiness, or publish an explicitly requested release. Use for release operations, not ordinary feature development.
---

# Prepare Storybird Release

요청한 릴리즈 작업을 실제 commit·검증 결과에 맞춰 수행한다. “준비”만 요청받으면
로컬 노트·검증·ZIP까지이며 원격 공개를 포함하지 않는다.

## 요청한 완료 상태를 유지한다

| 사용자 요청 | 완료 상태 |
|---|---|
| 릴리즈 준비 | 요청 범위의 로컬 버전·태그·노트·검증된 ZIP 준비 |
| 초안 등록 | GitHub Draft와 검증된 업로드 자산 |
| 준비된 버전의 릴리즈 등록·공개·최신으로 공개 | `--publish`로 공개하고 Latest·업로드 자산 확인 |
| 진행 중 상태 질문 | 현재 상태를 답하고 원래 요청의 완료까지 계속 진행 |

준비와 push 이후 “릴리즈 등록해줘”는 초안 요청이 아니라 공개 요청으로 해석한다.
초안은 사용자가 초안을 요청했을 때만 최종 결과가 된다. 공개 과정의 내부 초안 생성은
중간 단계이므로 거기서 멈추거나 공개 권한을 다시 묻지 않는다.

## 요청과 상태부터 확인한다

기존 버전을 지정한 요청은 해당 `vX.Y.Z` 태그를 대상으로 삼는다. 태그가 없거나
다음 버전의 신규 준비라면 사용자 지정 ref 또는 HEAD에서 후보를 정한다.
작업공간 지침은 이미 읽은 내용을 재사용하고, 아래에서 필요한 자료만 추가로 읽는다.

```bash
.agents/skills/prepare-storybird-release/scripts/collect_release_facts.sh --target <ref> --online
```

수집기는 읽기 전용이다. `--json`은 같은 사실을 구조화해 반환한다.
네트워크를 사용하지 않으면 `--online`을 생략한다.

- `local_tag`, `remote_tag`, `release_state`는 서로 다른 상태다.
  로컬 태그나 draft만으로 이미 공개됐다고 판단하지 않는다.
- `release_state: unknown`은 조회 실패 또는 미조회다. `absent`로 간주하지 않는다.
- `comparison`은 도달 가능한 이전 공개 릴리즈 기준이다. 기준을 확인하지 못하면
  변경 목록을 완전하다고 보고하지 않는다.
- 태그/commit 충돌은 먼저 해결한다. 기존 버전의 공개 요청이면 이미 공개된 것을
  다시 공개하지 않는다. 새 변경 없이 버전을 자동으로 올리지 않는다.
  다음 버전 준비와 요청받은 감사는 실제 변경·공개 상태를 근거로 계속한다.

## 필요한 작업만 수행한다

| 요청 | 읽을 자료와 수행 범위 |
|---|---|
| 현재 상태·준비 여부 확인 | 수집 결과와 기존 검증 기록. 빈 항목은 미확인으로 구분 |
| 노트 작성·수정 | [release-notes.md](references/release-notes.md). 실제 변경 근거 확인 |
| 새 버전 준비·빌드·패키징 | [prepare-and-verify.md](references/prepare-and-verify.md) |
| 준비된 버전의 초안·공개 | [publish.md](references/publish.md). 새 버전 선정부터 반복하지 않음 |

상태 감사 중 새 검증이 필요할 때만 해당 준비 절차를 읽는다. 준비된 산출물은
대상 commit·checksum과 기존 증거를 대조해 재사용한다. 코드나 산출물이 바뀌었거나
검증이 실패·누락됐을 때 필요한 범위를 다시 검증한다.

## 실제 차단과 미수행 검증을 구분한다

태그·대상 commit·번들 버전·checksum 불일치, 빌드·서명·자동 테스트의 확인된 실패,
업로드 오류, 원격 상태 조회 실패, 확인된 데이터 손실·보안 결함은 해결한 뒤 공개한다.
사용자가 이번 공개의 필수 조건으로 지정한 검사가 미완료인 경우도 그 조건을 따른다.

수동 smoke test나 선택적 성능 검사의 미수행만으로 명시적인 공개 요청을 초안으로
낮추지 않는다. 미수행 사실과 검증 범위를 노트에 남기고, 실제 차단이 없으면 공개까지
진행한다. 변경 없는 대상에 전체 테스트·재빌드·재승인을 반복하지 않는다.
과거 준비 기록의 보류 판정도 현재 요청과 실제 사유로 재평가한다. 미수행 표시를 확인된
실패로 바꾸어 해석하지 않는다.

## 모든 모드에서 지킬 경계

- 미커밋 변경을 릴리즈에 임의로 포함하거나 되돌리지 않는다. 캡처·개인 프로젝트·
  자격 증명을 노트나 자산에 넣지 않는다.
- 공개된 태그와 자산을 덮어쓰지 않는다. 미완료 검증을 통과로 표시하지 않는다.
- Git push는 사용자가 `.devcontainer`에서 한다. 요청받은 초안·공개는 로컬 `gh`로
  수행할 수 있다. 이미 받은 권한을 재확인하지 않는다.
- 버전·노트·패키징은 운영 작업이다. 제품 동작 계약을 바꿔야 한다면 별도로 ADR
  admission gate를 적용한다.

결과에는 대상 버전/commit, 변경 요약, 노트·ZIP 경로와 checksum, 검증 및 미확인 항목,
commit·tag·push·draft·공개 중 완료된 상태를 구분해 보고한다.
