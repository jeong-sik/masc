---
rfc: "stack-type-check-runs-at-the-top"
title: "스택의 type-check 는 꼭대기 PR 에서 한 번 돈다"
status: Draft
created: 2026-11-12
updated: 2026-11-12
author: claude
supersedes: []
superseded_by: null
related: []
implementation_prs: []
---

# RFC: 스택의 type-check 는 꼭대기 PR 에서 한 번 돈다 (stack-type-check-runs-at-the-top)

## 0. 요약

native stack 의 PR 은 지금 층마다 `dune build @check` 를 돈다.
위층의 소스 트리는 아래층 변경을 전부 담는다. 꼭대기에서 통과하면 스택 전체를 합친 트리가 컴파일된다.

이 RFC 는 스택에 속한 PR 의 type-check 를 꼭대기 PR 에서만 돌린다.
아래층의 type-check 는 `skipped` 가 된다. 꼭대기는 스택 전체 diff 로 소스 변경을 판정한다.

대가는 §5 에 있다. 사용자가 정할 것은 §8 에 있다.

## 1. 배경 (측정)

2026-11-12, 스택 #51256(열린 층 84개).

- `sse/` 브랜치 층 83개 가운데 50개가 type-check 를 돌았고 33개는 `skipped` 였다(03:05Z 집계).
- type-check job 한 번은 368~533초였다(01:35Z restack 의 성공한 job 5개).
- 스택을 한 번 다시 올리면 type-check 가 약 50번 돈다. 이날 이 스택은 세 번 다시 올라갔다(01:35Z, 04:42Z, 04:43Z).
- 04:40Z~04:53Z 에 만들어진 `pr-type-check` 실행 166개 가운데 93개가 이 스택 것이었다. 04:53Z 에 그중 36개가 queued, 14개가 in_progress 였다.

저장소에는 2시간에 PR 이 100개쯤 들어온다. runner 는 한정돼 있다.

## 2. 문제

type-check 실행 수가 스택의 층 수에 비례한다. 증명에 필요한 것은 한 번이다.

지금 꼭대기의 초록은 그 증명도 아니다. #51448(꼭대기)은 dashboard 파일만 바꿔서 type-check 가 `skipped` 다.
실제로 전체를 증명하는 것은 "type-check 가 돈 층 가운데 가장 위"이고, 그 위에 OCaml 변경이 없을 때만이다.

## 3. 지금 workflow 가 하는 일

`.github/workflows/pr-type-check.yml`:

- `changes` job 은 PR 의 merge commit 과 그 첫 부모를 비교해 파일 목록을 얻는다. 스택 PR 의 첫 부모는 바로 아래층이다. 그래서 판정은 그 층 하나의 변경만 본다.
- `type-check` job 은 `changes` 가 소스 변경을 찾았을 때만 돈다. 아니면 `skipped` 다.
- main ruleset 은 PR 마다 `changes` 와 `type-check` 를 요구한다. `skipped` 는 통과로 친다.

GitHub 문서가 말하는 것([stack API](https://docs.github.com/en/pull-requests/reference/stacked-pull-requests-apis-and-webhooks), [스택 병합](https://docs.github.com/en/pull-requests/how-tos/merge-and-close-pull-requests/merging-stacked-pull-requests), 2026-11-12 확인):

- 스택에 속한 PR 은 webhook payload 의 `pull_request` 에 `stack` 이 붙는다. REST 의 `stack` 은 `number`, `position`, `size`, `base{ref, sha}` 를 가진다. webhook 쪽 필드 목록은 문서에서 확인하지 못했다(§7 의 0단계).
- PR 이 스택에 들어가면 `pull_request` 이벤트의 `stacked` action 이 온다. 스택에서 빠질 때의 action 은 찾지 못했다.
- 병합 조건: "All pull requests below it are approved and have passing checks."
- 부분 병합이 된다: "You can merge any number of pull requests at once, as long as they form a contiguous group starting from the lowest unmerged pull request."

병합 worker(`scripts/review/approval-auto-merge.py`)는 검사 결과를 읽지 않는다. 승인과 스택 모양만 확인하고, 검사는 GitHub 의 규칙에 맡긴다. worker 는 늘 스택 전체를 꼭대기 PR 로 병합한다.

## 4. 설계

### 4.1 `changes` job

payload 의 `stack` 을 읽는다. REST 는 부르지 않는다(#51475 가 이 job 에서 REST 를 뺀 이유가 Actions 토큰 한도다).

| 경우 | 판정 |
|---|---|
| `stack` 이 없다 | 지금과 같다 |
| `position < size` (아래층) | `src=false`. 로그에 "스택 #N 의 꼭대기가 검사한다"를 남긴다 |
| `position == size` (꼭대기) | merge commit 과 `stack.base.sha` 를 비교한 파일 목록으로 판정한다 |
| `stack` 은 있는데 필드가 숫자가 아니거나 `base.sha` 가 없다 | 지금과 같다(그 층의 변경으로 판정) |

- 꼭대기의 비교는 지금과 같은 blobless fetch 다. 받는 commit 이 하나 늘어난다(`stack.base.sha`).
- 모르는 모양은 검사를 더 하는 쪽으로 떨어진다. 검사를 덜 하는 쪽으로 떨어지는 갈래는 "아래층" 하나다.
- workflow 의 `on.pull_request` 에 `stacked` 를 더한다. 독립 PR 이 스택의 아래층이 되면 다시 판정한다.

### 4.2 병합 worker

아래층의 `skipped` 는 "꼭대기가 검사했다"는 뜻이다. 그 꼭대기가 실제로 검사했는지는 worker 가 확인한다.

native stack 을 병합하기 전에 worker 는 꼭대기 PR 의 현재 head 에서 `type-check` check-run 을 읽는다.

- `success` 면 진행한다.
- `skipped` 면 스택 전체에 소스 변경이 없는지 직접 확인한다(`compare/{stack.base.sha}...{꼭대기 head}`). 소스가 없으면 진행한다. 있으면 `Hold` 다. 파일이 300개(compare 상한)에 닿으면 `Hold` 다.
- 그 밖(실패, 진행 중, 없음)은 `Hold` 다.

이 확인이 막는 경우:

- 꼭대기 PR 이 닫히거나 스택에서 빠져서 아래층이 새 꼭대기가 됐다. 그 층의 `skipped` 는 옛 꼭대기에 맡긴 결과다. 새 이벤트가 오지 않으므로 `changes` 는 다시 돌지 않는다.
- 닫힌 채 병합되지 않은 PR 이 꼭대기에 남아 있다. 그 아래 열린 PR 은 `position < size` 라서 아래층으로 판정된다.

`Hold` 메시지는 다음 한 단계를 적는다: 꼭대기 PR 의 `pr-type-check` 를 다시 돌린다.

### 4.3 바뀌지 않는 것

- main ruleset 의 필수 검사 이름(`changes`, `type-check`).
- 스택이 아닌 PR 의 판정.
- `changes` 가 빨갛게 실패하면 병합을 막는 것(fail-closed).

## 5. 대가

1. **부분 병합은 검사 없이 통과한다.** GitHub 은 아래에서부터 이어진 층을 따로 병합하게 해 준다. 그 층들의 type-check 는 `skipped` 라서 규칙을 통과한다. 병합되는 트리(중간 층)는 아무도 컴파일해 보지 않았다. worker 는 부분 병합을 하지 않는다. 사람이 UI 나 API 로 하면 생긴다. 병합 뒤 `main-minimal-build` 가 잡는다. 2026-11-03 에 PR 단계 type-check 없이 병합된 PR 셋이 main 의 type-check 를 깨뜨렸고, `pr-type-check` 는 그래서 생겼다(workflow 머리 주석).
2. **중간 층이 단독으로 컴파일되는지 모른다.** 스택을 통째로 병합하면 main 에는 층마다 commit 이 하나씩 생긴다. 중간 commit 에서 `git bisect` 가 빌드 실패를 만날 수 있다.
3. **실패한 층을 가리키지 못한다.** 꼭대기에서 실패하면 어느 층이 원인인지는 컴파일 오류의 파일로 찾아야 한다.

## 6. 고르지 않은 것

- **지금대로 둔다.** 대가가 없다. restack 한 번에 type-check 약 50번이 그대로다.
- **가장 위의 OCaml 층에서만 돈다.** 꼭대기가 dashboard 층이어도 도는 층이 하나로 정해진다. 층마다 "내 위에 OCaml 변경이 있는가"를 알아야 하는데, payload 에는 위층 정보가 없다. REST 를 층마다 불러야 한다.
- **diff 가 그대로인 rebase 는 건너뛴다.** 이전 head 의 결과를 찾아야 해서 REST 가 든다. base 가 움직였으므로 이전 결과가 지금 트리를 증명하지도 않는다.
- **부분 병합을 규칙으로 막는다.** GitHub 에 "스택은 통째로만"이라는 규칙이 없다. 아래층에 늘 빨간 필수 검사를 두면 통째 병합도 막힌다.

## 7. 하네스와 구현 순서

0. **payload 확인.** `changes` 가 `github.event.pull_request.stack` 을 로그에 한 줄 찍는다. 동작은 안 바꾼다. 스택 PR 한 번의 실행에서 `number`, `position`, `size`, `base.sha` 가 오는지, 병합된 층이 `position`·`size` 에 세이는지 본다. 필드가 없으면 이 RFC 는 GraphQL `stackEntry`(REST 와 한도가 따로다)로 다시 쓴다.
1. **판정 스크립트와 시험.** 판정을 workflow 의 inline bash 에서 스크립트로 옮긴다. 입력은 payload 의 `stack` 과 파일 목록 둘, 출력은 `src` 다. §4.1 의 표 네 줄과 "꼭대기가 dashboard 층이고 아래층에 `.ml` 이 있다"를 시험한다.
2. **worker 확인과 시험.** `scripts/review/test_approval_auto_merge.py` 에 §4.2 의 갈래를 더한다.
3. **1과 2를 한 스택으로 올린다.** 1만 들어가면 §4.2 가 막는 경우가 열린다.
4. **측정.** 층 10개 이상인 스택의 다음 restack 에서 `pr-type-check` 실행 수와 queued 시간을 §1 과 비교한다.

## 8. 사용자 결정

1. **부분 병합이 검사 없이 통과하는 것(§5-1)을 받아들인다.** 근거: 헌법은 native stack 을 꼭대기 PR 로 통째로 병합하게 하고, worker 도 그렇게만 한다. 얻는 것은 restack 한 번에 type-check 약 49번이다. 대가: 사람이 스택 일부만 병합하면 컴파일해 보지 않은 트리가 main 에 들어가고, 병합 뒤 빌드가 그것을 알린다. 받아들이지 않으면 §6 의 "지금대로 둔다"가 남는다.
2. **부분 병합 전에 사람이 할 일을 안내서에 적을지.** 적는다면: 병합할 맨 위 층의 브랜치에서 `pr-type-check` 를 `workflow_dispatch` 로 돌리고 초록을 본 뒤 병합한다. 이 실행은 병합을 막지 못한다. 확인용이다.
