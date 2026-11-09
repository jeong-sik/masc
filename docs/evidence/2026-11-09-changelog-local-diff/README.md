# Changelog 파일 목록을 로컬 Git으로 확인한 기록

[이슈 #50404](https://github.com/jeong-sik/masc/issues/50404)의 CI 수리 기록이다.
기존 workflow는 checkout 뒤 PR 파일 목록을 REST API로 읽다가 installation
rate limit(HTTP 403)에 걸려 fragment 검사 전에 종료됐다. 실패한 두 실행의
attempt 1과 head/ref는 [observations.json](observations.json)에 기록했다.
run 42562649386의 후속 재실행은 성공했으므로 그 run 전체가 여전히 실패했다고
해석하지 않는다. 후속 성공은 이 패치의 실행 결과도 아니다.

[수정한 workflow](../../../.github/workflows/changelog-fragments.yml)는
`fetch-depth: 2`로 가져온 synthetic merge와 첫 부모의 tree를 비교한다.
PR의 실제 base를 쓰므로 변경하지 않은 아래층 fragment는 검사하지 않는다.
rename은 삭제와 추가로 다루고 삭제된 경로와 루트 `README.md`를 제외한다.
NUL로 나눈 파일명은 각각 하나의 argv로 기존 checker에 전달한다.
Git 비교 실패는 그대로 실패하며 빈 목록으로 처리하지 않는다.
수동 `workflow_dispatch`의 전체 fragment 검사는 유지한다.

이 선택은 GitHub의 [pull_request checkout 계약](https://docs.github.com/en/actions/reference/workflows-and-actions/events-that-trigger-workflows#pull_request),
고정한 [checkout 버전의 depth 2 예제](https://github.com/actions/checkout/blob/3d3c42e5aac5ba805825da76410c181273ba90b1/README.md#checkout-head),
Git의 [NUL 출력과 diff 필터](https://git-scm.com/docs/git-diff)를 확인한 뒤 했다.

검증은 workflow에 적힌 PR·수동 실행문을 그대로 추출해 실제 Git merge와
깊이 2의 얕은 checkout에서 실행했다. 기존 checker도 함께 실행했다.
파일 목록 API가 다시 필요해지면 실패하도록 fixture의 `gh`는 거부 stub이다.
다음 15개 경우의 기대 결과와 checker argv가 모두 맞았다.

- fragment 추가·수정과 잘못된 citation 거부
- 삭제만 있는 변경과 README만 있는 변경
- 디렉터리 안의 rename, 밖으로 이동, 안으로 이동
- 공백·tab·줄바꿈·glob·한글을 포함한 파일명 보존과 잘못된 경로 거부
- base가 따로 이동한 상위층에서 아래층 fragment 제외
- 첫 부모가 없는 depth 1 checkout의 실패와 수동 전체 검사의 성공·실패

`actionlint` 1.7.12와 `git diff --check`도 성공했다. base는
`1cab54b0abea9df91a3882604111ba987ee27f10`이다. 이후 main의 변경,
실제 GitHub runner에서 이 패치의 성공, Dune 빌드와 Full CI는 검증하지 않았다.

이 디렉터리는 공개용 파생본이다. 호스트 경로가 든 원본 결과·fixture와
실패 로그는 `artifacts/pr-update-20261109T042654Z/`에 남겨 두었다.
JSON에는 원본 결과와 로그의 SHA-256, 검사한 workflow와 checker의 SHA-256을
남겼다. 원본 해시가 이 파생 JSON의 바이트를 인증하는 것은 아니다.
초기 로컬 helper의 `head` 브랜치 이름은 macOS에서 `HEAD`와 충돌했다.
보존한 재현본은 별도 이름과 명시적 ref를 쓰며 두 부모를 먼저 확인한다.

재현하려면 Git, Python 3와 PyYAML이 필요하다. 저장소 루트에서 실행한다.

```bash
python3 docs/evidence/2026-11-09-changelog-local-diff/reproduce.py
actionlint .github/workflows/changelog-fragments.yml
git diff --check
```

새 실행의 기본 출력은 `artifacts/changelog-local-diff/<UTC 시각>/`이다.
`--repo`와 `--output-dir`로 경로를 지정할 수 있다. 이 디렉터리의 보존 기록은
재현 명령이 덮어쓰지 않는다.
