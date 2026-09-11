# 준비된 릴리즈 초안과 공개

대상 버전의 기존 태그 commit, ZIP, 노트와 검증 기록에서 이어서 작업한다.
현재 HEAD가 나중의 운영 커밋이라도 이미 준비한 버전의 대상을 바꾸지 않는다.

## 태그 전달

Git push는 사용자가 `.devcontainer`에서 실행한다. macOS에서 준비한 annotated tag를
검증하고 아래 명령에 실제 버전을 넣어 전달한다.

```bash
./scripts/push-version.sh X.Y.Z
```

이 명령은 해당 태그와 필요한 commit만 올린다. branch를 추가로 push하지 않는다.
ZIP·checksum 입력이나 별도 `gh` 인증은 필요 없으며 동일한 원격 태그는 성공으로 끝난다.
태그가 없으면 로컬 준비부터, 태그가 다르면 충돌 확인부터 수행한다. 덮어쓰지 않는다.

## 로컬 gh 작업

이미 push된 태그는 다시 push하도록 요구하지 않는다. 첫 원격 변경 전에 버전, target SHA,
제목, 최종 노트와 ZIP checksum을 사용자에게 보여준다. 기존 공개 요청과 권한은 재사용한다.

기존 스크립트에 검증된 값을 넣어 실행한다. checksum은 검증된 ZIP 기록에서 가져온다.

```bash
bash scripts/publish-release.sh X.Y.Z FULL_COMMIT_SHA VERIFIED_ZIP_SHA256
bash scripts/publish-release.sh X.Y.Z FULL_COMMIT_SHA VERIFIED_ZIP_SHA256 --draft
```

첫 명령은 읽기 전용 검증이다. `--draft`는 초안을 생성하거나 일치하는 초안을 재검증한다.
스크립트가 태그, 제목·본문, 자산 이름과 업로드 후 다시 내려받은 ZIP의 checksum을 검증한다.
직접 `gh`로 작업해야 할 때도 이 검증을 유지한다.

공개 요청이 있고 필요한 검증이 완료됐을 때만 실행한다.

```bash
bash scripts/publish-release.sh X.Y.Z FULL_COMMIT_SHA VERIFIED_ZIP_SHA256 --publish
```

관련 native smoke 검증이 미완료이면 공개하지 않고 완료된 초안과 차단 항목을 보고한다.
준비만 요청한 경우에도 공개하지 않는다. 동일한 입력의 완전한 초안은 재사용하되,
부분 업로드·본문 불일치·조회 실패를 새 릴리즈가 없는 상태로 취급하지 않는다.

공개 후 `isDraft=false`, 대상 태그, Latest, 자산 checksum을 확인한다. 다운로드한 앱의
서명도 가능한 환경에서 대조한다. `--clobber`나 태그 이동으로 공개 내용을 바꾸지 않는다.
실패 시 이미 완료된 원격 단계와 남은 작업을 구분한다.
