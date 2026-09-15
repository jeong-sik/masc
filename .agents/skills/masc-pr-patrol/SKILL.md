---
name: masc-pr-patrol
description: "masc 저장소의 열린 PR 을 순찰한다. 담당·라벨·리뷰어를 정리하고, 빨간 CI 가 내 변경 탓인지 낡은 base·취소·시간 초과 탓인지 가르고, 병합 전에 초록이 실제로 무엇을 증명하는지 확인한다. PR 스윕, CI 빨강, check 실패, 머지해도 되나, 스택 PR 병합, check-run 조회 때 쓴다. OCaml 코드를 쓰는 일이나 TUI 화면 판정에는 쓰지 않는다."
---

# masc PR 순찰

모든 명령은 저장소 이름을 이렇게 받아 쓴다. 이름을 손으로 적지 않는다.

```sh
REPO=$(gh repo view --json nameWithOwner -q .nameWithOwner)
```

`gh pr view`·`gh pr checks`·`gh pr ready`·`gh pr merge` 는 GraphQL 을 쓴다. GraphQL 한도는
계정 하나를 여러 세션이 같이 쓰기 때문에 순찰 도중에 막힌다. 조회와 병합은 `gh api repos/...`
(REST) 로 한다. REST 로 못 하는 것은 Draft → Ready 하나다.

## 이 저장소의 PR 체크

`.github/workflows/pr-check.yml` 에서 확인한 사실이다. 판단이 이상하면 이 파일부터 다시 읽는다.

- PR 이 열리거나(`opened`) push 되거나(`synchronize`) 다시 열릴 때(`reopened`)만 돈다.
  Draft → Ready 전환은 새 run 을 만들지 않는다.
- 동시성 그룹이 `pr-check-<PR 번호>` 이고 `cancel-in-progress: true` 다. 새 push 가 오면 앞 run 은
  `cancelled` 로 끝난다.
- 체크는 넷이다: `lint suite`, `dune build @check`, `dune build --profile release @check`,
  `dashboard typecheck`.
- `dune build @check` 잡의 마지막 스텝 `Run the tests this pull request edits` 가
  `scripts/ci/run-edited-tests.sh <PR 번호>` 를 돌린다. 고른 스위트가 실패하면 이 체크가 빨개진다.
  - 무엇이 돌았는지는 체크 이름에 안 나온다. 잡 로그의 `== <스위트>` 줄, `ran N, skipped M`,
    `suites that did not pass:` 로 본다.
  - 스위트는 바뀐 파일로 고른다. 바꾼 테스트 파일, 바꾼 모듈 이름과 맞는 스위트, 바꾼 경로를 적어 둔
    스위트가 들어간다. 편집한 테스트가 많아도 모두 남는다.
  - `test/test_tui_keyboard_input.py`(키보드 PTY 산책)는 지금 그 파일을 고친 PR 에서만 돈다.
    소스 경로를 문자열로 적어 두지 않아서 다른 규칙이 고르지 않는다. TUI 렌더만 바꾼 PR 의 초록은
    그 산책의 증거가 아니다.
  - `test/ci-known-failures.txt` 에 적힌 스위트는 `listed in` 으로 건너뛴다.
  - 스위트 하나의 상한은 300초, 키보드 산책만 600초다. `timeout` 이 끊으면 출력이 안 남는다.
- CI 가 컴파일하는 트리는 PR head 가 아니라 `refs/pull/<N>/merge`, 즉 head 를 그 순간의 main 에
  합친 트리다. 로그의 줄 번호가 내 파일과 안 맞으면 합친 트리 탓이다.
- PR 이 main 과 충돌하면(`mergeable_state` 가 `dirty`) GitHub 이 run 을 아예 만들지 않는다.

## 1. 순찰 순서

1. 열린 PR 을 한 번에 받는다.

   ```sh
   gh api --paginate "repos/$REPO/pulls?state=open&per_page=100" \
     --jq '.[] | [.number, .draft, .head.sha, .user.login,
                  ([.assignees[].login] | join(",")),
                  ([.labels[].name] | join(","))] | @tsv'
   ```

2. 손대기 직전에 그 PR 의 head sha 를 다시 읽는다. 목록을 받은 뒤 바뀌었으면 누군가 밀고 있는
   것이다. 그 PR 은 이번 순찰에서 뺀다.
3. 담당이 비어 있으면 작성자를 담당으로 둔다. 2026-09-14 부터 2026-09-15 조회 시점까지 열린 PR
   307건 중 202건이 이렇게 작성자가 담당이었다.

   ```sh
   gh api -X POST "repos/$REPO/issues/<N>/assignees" -f 'assignees[]=<작성자>'
   ```

4. 리뷰어는 작성자 말고 요청할 사람이 있을 때만 건다. GitHub 은 작성자 본인에게 리뷰 요청을
   받지 않는다. 지금 PR 은 거의 모두 저장소 소유자 계정이 올린다. 그래서 요청할 사람이 없으면
   비워 두고 보고에 적는다.

   ```sh
   gh api -X POST "repos/$REPO/pulls/<N>/requested_reviewers" -f 'reviewers[]=<계정>'
   ```

5. 라벨은 이미 정의된 PR 상태 라벨 넷만 쓴다. 새 라벨은 만들지 않는다.

   | 라벨 | 뜻 |
   |---|---|
   | `pr/conflict` | 다른 수정과 부딪혀 합칠 수 없다. CI 도 새로 안 돈다 |
   | `pr/review-approved` | 리뷰 통과. 검사만 초록이면 합칠 수 있다 |
   | `pr/review-changes` | 리뷰가 수정을 요청했다. 올린 사람 차례다 |
   | `pr/unresolved` | 안 닫힌 리뷰 댓글이 남았다 |

   ```sh
   gh api -X POST "repos/$REPO/issues/<N>/labels" -f 'labels[]=pr/conflict'
   gh api -X DELETE "repos/$REPO/issues/<N>/labels/pr%2Fconflict"   # 상태가 풀리면 뗀다
   ```

   `area/*`·`kind/*`·`impact/*`·`root/*` 는 이슈 어휘다. 어휘 원본은 `.github/issue-taxonomy.json`
   이고, `Issue Taxonomy` 워크플로가 이슈 본문의 `masc-triage` 블록을 읽어 이슈에만 붙인다.
6. main 보다 뒤처진 브랜치는 이렇게 갱신한다. 방금 읽은 head 에 고정한다.

   ```sh
   gh api -X PUT "repos/$REPO/pulls/<N>/update-branch" -f expected_head_sha=<40자 sha>
   ```

   `anyang-keepers` 계정도 열린 PR 브랜치에 `Merge branch 'main' into <branch>` 를 자동으로 올린다.
   그 merge 에서 충돌이 났던 파일은 main 쪽 수정이 남았는지 확인한다.
   `git diff <merge 커밋>^2 <merge 커밋> -- <파일>` 에서 main 이 넣은 줄이 지워져 나오면 빠진 것이다.
7. 빨간 체크가 있으면 2절로 간다.

## 2. CI 빨강 — 누구 탓인지 가르기

로그 전문을 읽기 전에 아래를 순서대로 본다. 앞 단계에서 답이 나오면 멈춘다.

1. **그 run 이 지금 head 의 것인가.** check-run 의 `head_sha` 가 PR 의 `.head.sha` 와 다르면
   지난 커밋의 판정이다.
2. **`cancelled` 인가.** 새 push 가 앞 run 을 끊은 것이다. 실패가 아니다. `gh pr checks` 표는
   취소도 `fail` 로 보여 주니 check-run 의 `conclusion` 으로 판단한다.
3. **`lint suite` 의 `PR run is not stale` 스텝인가.** run 이 만들어진 뒤 브랜치가 움직였다는
   뜻이다(자동 merge 포함). 코드 문제가 아니다.
4. **실패한 스텝 이름을 싸게 얻는다.** check-run 의 `id` 가 Actions 잡 id 와 같다.

   ```sh
   gh api "repos/$REPO/actions/jobs/<id>" \
     --jq '[.steps[] | select(.conclusion == "failure") | .name] | join(", ")'
   ```

5. **같은 스텝이 다른 열린 PR 에서도 빨간지 센다.** 빨간 PR 수가 아니라 "같은 스텝" 이 빨간 PR 수다.
   낡은 base 를 가진 PR 은 원래 여럿 빨갛다. 스텝이 다 다르면 그 숫자는 알리바이가 못 된다.
   - 같은 스텝·같은 스위트가 둘 이상이면 공통 원인이다. 대개 main 이 이미 깨졌거나 이미 고쳤다.
     코드를 고치지 말고 base 부터 최신으로 올린다.
   - 그 PR 에서만 빨가면 그때 로그를 읽는다.
6. **시간 초과인가.** 로그에서 `== <스위트>` 줄과 `ran N, skipped M` 줄의 시각 차가 상한(300초,
   키보드 산책 600초)과 같고 PASS 도 `AssertionError` 도 없으면 시간 초과다. 로그만으로는 느림과
   멈춤을 못 가른다. 상한 코앞의 스위트는 재실행해도 같은 결과가 나오기 쉽다.
7. **main 에서도 빨간가.** 스위트 이름으로 main 에서 한 번 돌려 대조한다.

   ```sh
   gh workflow run test.yml --ref main -f suite=<스위트 이름 또는 runtest alias 이름>
   ```

   main 에서도 빨가면 그 PR 에서 고치지 않는다. 이슈 하나로 적고 PR 에는 그 사실을 댓글로 남긴다.

원인을 찾기 전에 체크만 초록으로 만드는 수정은 하지 않는다. 실패를 세기만 하는 카운터, 문자열
분류기 보강, 몇 곳만 고친 패치, 상한·쿨다운으로 증상 누르기가 그런 수정이다. main 에 들어가면 다음
에이전트가 그 모양을 선례로 따라 한다. 지금 제품이 깨져 있어 어쩔 수 없을 때만 PR 본문에
`WORKAROUND:` 와 대신할 RFC 번호를 적고 넣는다.

### 재실행하기 전에

- 재실행은 처음 run 의 커밋(`GITHUB_SHA`)을 그대로 쓴다. 그 사이 main 에 들어온 수정은 반영되지
  않는다. main 이 고쳐졌으면 재실행 대신 1절 6번으로 브랜치를 갱신한다.
- 잡 로그의 checkout 에 찍힌 `Merge <head> into <base>` 의 base 가 지금 `origin/main` 과 다르면
  재실행해도 같은 트리다.
- 재실행은 원래 run 이 끝난 뒤에 누른다.

## 3. 병합 전에 — 초록이 증명하는 것

| 보이는 것 | 뜻 | 뜻이 아닌 것 |
|---|---|---|
| `dune build @check` 초록 | 컴파일됐고, 고른 스위트가 돌았다면 통과했다 | 편집 안 한 스위트가 통과했다 |
| `mergeable: true` / `MERGEABLE` | 충돌 표시가 없다 | 합친 트리가 빌드된다 |
| `dune build @runtest` 가 조용히 끝남 | 캐시에서 이전 결과를 재생했을 수 있다 | 방금 돌았다 (`--force` 출력이 증거) |
| PR 이 `merged` | 병합 버튼이 눌렸다 | 마지막으로 push 한 수정이 main 에 있다 |

- 체크가 끝나기 전에 병합하면 main 이 빨개질 수 있다. 병합 전 네 체크의 `conclusion` 이 전부 `success`
  인지 본다. `in_progress` 가 하나라도 있으면 기다리지 말고 다음 PR 로 넘어간다.
- Draft 는 병합되지 않는다(merge-async 가 `Pull request is in draft.` 로 거부). Ready 전환은 REST 에
  없어서 `gh pr ready` 가 필요하다. GraphQL 이 살아 있을 때 해 둔다.
- 병합은 맡겨진 경우에만 한다. 경로는 비동기 병합 API 하나다. 검증한 head 에 고정한다.

  ```sh
  gh api -X PUT "repos/$REPO/pulls/<N>/merge-async" -f merge_method=squash -f sha=<40자 sha>
  # 202 와 uuid 가 온다
  gh api "repos/$REPO/pulls/<N>/merge-async/<uuid>"
  ```

  폴링 결과가 `failed` 면 `details.message` 를 읽는다. 알려진 거부 메시지는 셋이다.
  - `Pull request is in draft.` → Ready 로 바꾼다.
  - `Required status check "dune build @check" is failing.` → PR 자기 체크가 초록이어도 base 브랜치
    쪽이 빨간 경우다. 스택이면 부모부터 초록으로 만든다.
  - `Stack needs to be rebased: ...` → 부모 브랜치를 자식 브랜치에 `git merge` 해 올리면 풀린다.
    force push 는 필요 없다. 아래 노드부터 한 칸씩 올린다.

  merge-async 가 500·502·빈 본문을 연달아 주면, 같은 head 에 고정해 스택이 아닌 PR 은
  `gh pr merge <N> --squash --match-head-commit <40자 sha>` 로 한 번 시도한다. 2026-09-13 에 이 길로
  병합된 적이 있다. 짧은 sha 를 주면 `Head branch was modified` 로 거부된다.
- **병합 뒤 도착을 확인한다.** squash 는 커밋 신원을 지운다. `git cherry`·`git log`·메시지 검색은
  답을 틀린다. 내용으로 비교한다.

  ```sh
  git fetch origin main
  git show origin/main:<파일> | rg '<이 PR 이 넣은 표식>'
  ```

- 병합된 PR 의 브랜치에 push 한 커밋은 main 에 가지 않는다. push 전에 PR 상태를 읽고, `MERGED` 나
  `CLOSED` 면 origin/main 에서 새 브랜치와 새 PR 을 만든다.

## 4. 스택 PR

- 자식 PR 의 base 는 부모 PR 의 head 브랜치다. 부모가 병합되면 GitHub 이 자식의 base 를 main 으로
  바꾼다. 이 저장소는 `delete_branch_on_merge` 가 켜져 있어 부모 브랜치가 바로 지워진다. 병합 뒤 자식
  PR 이 `closed` 로 떨어졌는지 확인한다. 닫혔으면 같은 head 로 새 PR 을 연다.
- 부모가 squash 로 병합돼도 자식 브랜치에는 부모의 원래 커밋이 남는다. 내용이 같아 충돌이 없고
  `MERGEABLE` 로 보이지만, 자식 PR 의 파일 목록에 부모가 고친 파일이 다시 나온다.

  ```sh
  gh api --paginate "repos/$REPO/pulls/<자식>/files?per_page=100" --jq '.[].filename'
  ```

  자식 브랜치에 `origin/main` 을 merge 해 올리고 파일 목록이 자식 것만 남았는지 다시 본다.
  양쪽이 같은 함수를 다른 위치에 넣었으면 merge 가 충돌 없이 두 벌을 남긴다. 부모가 넣은 정의가
  자식 diff 에 또 보이면 지운다.
- 스택 중간 노드는 부모가 초록이어야 병합된다(3절 거부 메시지 둘째).

## 5. check-run 조회

```sh
SHA=$(gh api "repos/$REPO/pulls/<N>" --jq .head.sha)

# 이름 하나의 가장 최근 run. 재실행 중인 run 까지 보려고 all 로 받아 시작 시각으로 정렬한다.
gh api -X GET --paginate "repos/$REPO/commits/$SHA/check-runs" \
  -f check_name='dune build @check' -f filter=all -f per_page=100 \
  --jq '.check_runs[] | [.started_at, .id, .status, (.conclusion // "-")] | @tsv' \
  | sort | tail -n 1
```

- 응답은 `total_count` 와 `check_runs` 다. 한 페이지 최대 100개이고 `--paginate` 가 나머지를 받는다.
- `filter` 기본값 `latest` 는 `completed_at` 기준으로 가장 최근 run 만 준다. 아직 안 끝난 run 을
  어떻게 다루는지는 문서에 없어서 `all` 로 받는다.
- 커밋 하나에 check suite 가 1000개를 넘으면 최근 check suite 1000개 안의 run 만 준다(GitHub REST 문서).
- 진행 중인 run 도 목록에 나온다. 이때 `conclusion` 은 `null` 이다.
- 잡 로그: `gh run view --job <id> --log`. 실패 부분만: `--log-failed`.

## Gotchas

- `gh pr checks --watch` 는 체크가 아직 등록되기 전이나 head 가 바뀐 순간 `no checks reported` 를
  찍고 exit 0 으로 끝난다. 판정이 아니다.
- 파이프를 붙이면 `$?` 는 마지막 명령의 종료 코드다. `cmd | tail; echo $?` 는 `cmd` 의 실패를 숨긴다.
- 키퍼 sandbox 이미지(`Dockerfile.keeper-sandbox`)에는 `gh` 가 설치돼 있다. `gh` 가 안 되면 먼저
  인증과 네트워크를 본다. TLS 우회 스크립트를 쓰지 않는다.
- 빈 커밋으로 CI 를 다시 부르지 않는다. `lint suite` 가 빈 커밋을 실패로 잡는다. main 보다 뒤처진
  브랜치면 브랜치 갱신(1절 6번)이 새 run 을 만든다.
- "이 오류가 더 안 난다" 고 말하려면, 지켜본 시간이 그 오류가 났던 간격 중 가장 긴 것보다 길어야
  한다. 짧으면 "없다" 가 아니라 "아직 못 봤다" 다.
- 판정은 상태 코드나 커밋 그래프가 아니라 내용으로 한다. HTTP 200 이 오류 화면을 줄 수 있고,
  squash 뒤에는 커밋 sha 로 도착을 확인할 수 없다.
