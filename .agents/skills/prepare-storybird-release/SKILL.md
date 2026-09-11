---
name: prepare-storybird-release
description: Prepare Storybird releases, write release notes, check readiness, or publish an explicitly requested release. Use for release operations, not ordinary feature development.
---

# Prepare Storybird Release

요청한 릴리즈 작업을 실제 commit·검증 결과에 맞춰 수행한다. “준비”만 요청받으면
로컬 노트·검증·ZIP까지이며 원격 공개를 포함하지 않는다.

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
