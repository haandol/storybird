# 로컬 릴리즈 준비와 검증

새 후보를 빌드·패키징하거나 기존 증거의 누락을 확인할 때 읽는다.
노트만 작성하거나 이미 검증된 ZIP을 공개할 때 전체 절차를 다시 수행하지 않는다.

## 후보와 버전

수집기가 확인한 이전 공개 기준부터 대상 commit까지 제목·본문·변경 파일을 읽는다.
관련 ADR, README, Troubleshooting은 변경 영향이 있는 부분을 확인한다.
PR/issue와 자동 생성 노트는 누락 확인에 사용하며 실제 diff를 대신하지 않는다.

지정 버전이 있으면 사용자 영향·호환성과 모순되지 않는지 확인한다. 새 버전은
Conventional Commits 신호, 저장 형식·최소 OS 변화, 기존 `0.1.x` 관례를 함께 고려한다.
`feat`만으로 증가 폭을 확정하지 않는다. 호환성을 깨는 변화는 드러내고 버전 의미를 확인한다.

다음 표기를 일치시킨다.

| 위치 | 값 |
|---|---|
| `Resources/Info.plist`의 `CFBundleShortVersionString` | `X.Y.Z` |
| `CFBundleVersion` | 이전 공개 build보다 큰 정수 |
| annotated tag / GitHub 제목 | `vX.Y.Z` / `Storybird X.Y.Z` |
| ZIP / 한국어 노트 | `build/Storybird-X.Y.Z.zip` / `build/release-notes-vX.Y.Z.md` |

버전 변경만 커밋한다면 `chore(build): bump version to X.Y.Z`를 사용한다.
커밋이 요청 범위에 없으면 로컬 변경으로 남기고, 확정된 commit이 필요한 배포와 구분한다.
커밋하지 않은 변경을 릴리즈 범위에 넣지 않는다. 빌드는 확정된 commit의 소스로 수행한다.
무관한 작업이 있으면 분리하고, 안전하게 분리할 수 없으면 패키징을 중단한다.

## 빌드와 실제 앱 검증

`CONTRIBUTING.md`의 빌드/서명 절과 `build.sh`를 확인한 뒤 macOS에서 실행한다.

```bash
swift test
./build.sh release
codesign --verify --deep --strict --verbose=2 build/Storybird.app
codesign --verify --strict --verbose=2 build/Storybird.app/Contents/MacOS/StorybirdMCP
codesign -dv --verbose=4 build/Storybird.app
codesign -dv --verbose=4 build/Storybird.app/Contents/MacOS/StorybirdMCP
```

앱과 companion에 실제 Apple Development 또는 Developer ID 신원과 같은 비어 있지 않은
TeamIdentifier가 있어야 한다. ad-hoc 서명을 권한 유지가 검증된 릴리즈로 승인하지 않는다.
현재 배포는 notarized가 아니며 설치 안내는 [노트 가이드](release-notes.md)를 따른다.

변경 영향에 해당하는 `AGENTS.md`/`CONTRIBUTING.md` 수동 smoke 결과는 기존 증거를
재사용하고, 새로 확인한 항목과 미수행 항목을 구분한다. 실제 캡처·클릭·마이크·권한 검증을
합성 테스트로 대체했다고 보고하지 않는다. 미수행만으로 공개 차단을 만들지 않는다.
사용자가 이번 공개의 필수 조건으로 지정했거나 실제 결함·검증 실패가 확인된 경우에만
그 사유를 차단 항목으로 기록한다. 단순 미수행과 확인된 실패를 같은 상태로 취급하지 않는다.

## 패키징

같은 이름의 기존 ZIP은 출처와 검증 기록을 먼저 확인해 재사용한다. 자동으로 덮어쓰지 않는다.
새 ZIP은 macOS 메타데이터를 보존해 만든다.

```bash
version="$(plutil -extract CFBundleShortVersionString raw Resources/Info.plist)"
archive="build/Storybird-${version}.zip"
test ! -e "$archive"
ditto -c -k --sequesterRsrc --keepParent build/Storybird.app "$archive"
unzip -t "$archive"
shasum -a 256 "$archive"
```

별도 임시 폴더에 압축을 풀어 앱 버전/build와 앱·companion 서명을 다시 검증한다.
임시 폴더는 자신이 만든 정확한 경로만 정리한다. 태그 commit, 번들, 파일명, 노트의 버전과
checksum이 일치해야 한다. 노트에는 실제 테스트 수·skip·실패와 서명·수동 검증 상태를 적는다.

정확한 release commit에 annotated tag를 로컬에서 준비한다. 기존 태그가 있으면 동일한
대상인지 확인하며 옮기지 않는다. 이후 추가한 운영 스크립트 커밋 때문에 태그를 옮기거나
앱을 재빌드할 필요는 없다. 원격 단계는 [publish.md](publish.md)를 따른다.
