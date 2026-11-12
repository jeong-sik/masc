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
병합 worker 는 병합을 요청하기 전에 `skipped` 가 무엇을 뜻하는지 직접 확인한다. 스택이든 독립 PR 이든 같다.

대가는 §5 에 있다. 사용자가 정할 것은 §8 에 있다.

## 1. 배경 (측정)

2026-11-12, 스택 #51256(열린 층 84개).

- `sse/` 브랜치 층 83개 가운데 50개가 type-check 를 돌았고 33개는 `skipped` 였다(03:05Z 집계).
- type-check job 한 번은 368~533초였다(01:35Z restack 의 성공한 job 5개).
- 스택을 한 번 다시 올리면 type-check 가 약 50번 돈다. 꼭대기에서만 돌면 한 번이다. 줄어드는 것은 약 49번이다. 이날 이 스택은 세 번 다시 올라갔다(01:35Z, 04:42Z, 04:43Z).
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
- 비교는 두 트리를 맞대는 `git diff A B` 다. merge base 를 찾지 않는다. `stack.base.sha` 가 스택이 갈라진 지점보다 새 main 이면 main 쪽 변경이 목록에 더 섞인다. 스택이 바꾼 파일은 빠지지 않는다. 목록이 늘어나는 쪽으로만 틀린다.
- 모르는 모양은 검사를 더 하는 쪽으로 떨어진다. 검사를 덜 하는 쪽으로 떨어지는 갈래는 "아래층" 하나다.
- workflow 의 `on.pull_request` 에 `stacked` 를 더한다. 독립 PR 이 스택의 아래층이 되면 다시 판정한다.

### 4.2 병합 worker

아래층의 `skipped` 는 "꼭대기가 검사했다"는 뜻이다. 이 뜻은 그 PR 이 그 스택의 아래층으로 남아 있는 동안만 맞다.
PR 이 스택에서 빠지거나 꼭대기가 사라지면 `skipped` 는 그대로 남고 뜻만 틀려진다. `skipped` 를 믿어도 되는지는 worker 가 병합 직전에 확인한다.

worker 는 승인과 스택 모양을 다 확인한 뒤(`prepare`), 병합을 요청하기 전(`submit`)에 병합 범위의 맨 위 PR 의 현재 head 에서 `type-check` check-run 을 읽는다. 스택이면 꼭대기 PR 이고, 독립 PR 이면 그 PR 자신이다.

- `success` 면 진행한다.
- `skipped` 면 병합 범위 전체에 소스 변경이 없는지 직접 확인한다. 스택은 `compare/{stack.base.sha}...{꼭대기 head}`, 독립 PR 은 `compare/{base sha}...{head}` 다. 소스가 없으면 진행한다. 있으면 `Hold` 다. 파일이 300개(compare 상한)에 닿으면 `Hold` 다.
- 그 밖(실패, 진행 중, 없음)은 `Hold` 다.

소스 패턴은 `changes` job 과 같은 목록을 쓴다. 목록은 한 곳에 두고 둘이 같이 읽는다(§7 의 1단계).

이 확인이 막는 경우:

- 아래층 PR 이 스택에서 빠져 독립 PR 이 됐다(base 를 main 으로 바꿨거나 스택이 풀렸다). head 가 그대로면 `pr-type-check` 를 깨우는 이벤트가 없다. 그 PR 의 `skipped` 는 옛 꼭대기에 맡긴 결과로 남는다. worker 는 독립 PR 로 보고 그 PR 의 diff 를 직접 읽는다.
- 꼭대기 PR 이 닫히거나 스택에서 빠져서 아래층이 새 꼭대기가 됐다. 그 층의 `skipped` 도 옛 꼭대기에 맡긴 결과다.
- 닫힌 채 병합되지 않은 PR 이 꼭대기에 남아 있다. 그 아래 열린 PR 은 `position < size` 라서 아래층으로 판정된다.

이 확인은 PR 이 스택을 떠날 때 오는 이벤트 이름을 몰라도 성립한다. worker 는 이벤트가 아니라 병합 시점의 상태를 읽는다.

읽는 시점은 병합을 요청하려는 실행뿐이다. `Hold` 로 끝나는 실행은 읽지 않는다.

`Hold` 메시지는 다음 한 단계를 적는다: 그 PR 의 브랜치에서 `pr-type-check` 를 `workflow_dispatch` 로 돌린다.
이 실행은 소스 판정 없이 type-check 를 돌리고, 결과를 같은 head commit 에 남긴다. 실패한 실행을 "다시 실행"하면 옛 payload 를 다시 써서 아래층 판정이 되풀이된다.
같은 head 에 `type-check` 가 여럿이면 worker 는 가장 새 것을 읽는다. 가장 새 것이 `skipped` 면 위의 직접 확인으로 간다.

### 4.3 바뀌지 않는 것

- main ruleset 의 필수 검사 이름(`changes`, `type-check`).
- 스택이 아닌 PR 의 판정.
- `changes` 가 빨갛게 실패하면 병합을 막는 것(fail-closed).

## 5. 대가

1. **부분 병합은 검사 없이 통과한다.** GitHub 은 아래에서부터 이어진 층을 따로 병합하게 해 준다. 그 층들의 type-check 는 `skipped` 라서 규칙을 통과한다. 병합되는 트리(중간 층)는 아무도 컴파일해 보지 않았다. worker 는 부분 병합을 하지 않는다. 사람이 UI 나 API 로 하면 생긴다. 병합 뒤 `main-minimal-build` 가 잡는다. 2026-11-03 에 PR 단계 type-check 없이 병합된 PR 셋이 main 의 type-check 를 깨뜨렸고, `pr-type-check` 는 그래서 생겼다(workflow 머리 주석).
2. **중간 층이 단독으로 컴파일되는지 모른다.** 스택을 통째로 병합하면 main 에는 층마다 commit 이 하나씩 생긴다. 중간 commit 에서 `git bisect` 가 빌드 실패를 만날 수 있다.
3. **실패한 층을 가리키지 못한다.** 꼭대기에서 실패하면 어느 층이 원인인지는 컴파일 오류의 파일로 찾아야 한다.
4. **worker 의 API 호출이 는다.** 병합을 요청하는 실행마다 check-run 읽기가 한 번 든다. 맨 위 PR 의 type-check 가 `skipped` 면 compare 가 한 번 더 든다. 문서나 dashboard 만 바꾼 독립 PR 이 여기에 든다. 지금은 0번이다.
5. **꼭대기가 `skipped` 인 큰 스택은 멈춘다.** compare 는 파일을 300개까지만 준다. 꼭대기가 소스를 바꾸지 않았고 스택 전체가 300개 넘게 바꿨으면 worker 는 소스가 없다고 확인하지 못해 `Hold` 다. 이때는 꼭대기 브랜치에서 `pr-type-check` 를 `workflow_dispatch` 로 한 번 돌려야 한다(§4.2 의 `Hold` 메시지).
6. **사람이 직접 병합하는 길은 이 확인을 지나지 않는다.** ruleset 은 `skipped` 를 통과로 친다. 스택에서 빠진 PR 을 사람이 UI 로 병합하면 1번과 같은 일이 생긴다.

## 6. 고르지 않은 것

- **지금대로 둔다.** 대가가 없다. restack 한 번에 type-check 약 50번이 그대로다.
- **가장 위의 OCaml 층에서만 돈다.** 꼭대기가 dashboard 층이어도 도는 층이 하나로 정해진다. 층마다 "내 위에 OCaml 변경이 있는가"를 알아야 하는데, payload 에는 위층 정보가 없다. REST 를 층마다 불러야 한다.
- **diff 가 그대로인 rebase 는 건너뛴다.** 이전 head 의 결과를 찾아야 해서 REST 가 든다. base 가 움직였으므로 이전 결과가 지금 트리를 증명하지도 않는다.
- **`pr-type-check` 를 base 가 바뀔 때 다시 돌린다.** base 변경은 `edited` action 으로 온다. `edited` 는 제목·본문 수정에도 오고, trigger 단계에서 base 변경만 고를 수 없다. 제목을 고칠 때마다 실행이 하나 생기고, 같은 PR 의 진행 중인 type-check 를 취소한다(concurrency 그룹이 PR 단위다). 스택이 풀릴 때 오는 action 은 이름도 모른다. §4.2 는 이벤트 없이 같은 구멍을 막는다.
- **부분 병합을 규칙으로 막는다.** GitHub 에 "스택은 통째로만"이라는 규칙이 없다. 아래층에 늘 빨간 필수 검사를 두면 통째 병합도 막힌다.

## 7. 하네스와 구현 순서

0. **payload 확인.** `changes` 가 `github.event.pull_request.stack` 을 로그에 한 줄 찍는다. 동작은 안 바꾼다. 스택 PR 한 번의 실행에서 `number`, `position`, `size`, `base.sha` 가 오는지, `position`·`size` 가 병합된 층도 세는지 본다. `base.sha` 가 스택이 갈라진 지점인지 main 의 지금 끝인지도 본다(main 이 움직인 뒤의 실행에서 비교한다). PR 이 스택에서 빠질 때 `pull_request` 이벤트가 오는지, 오면 action 이름이 무엇인지 기록한다. 설계는 이 이름에 기대지 않는다. 필드가 없으면 이 RFC 는 GraphQL `stackEntry`(REST 와 한도가 따로다)로 다시 쓴다.
1. **판정 스크립트와 시험.** 판정을 workflow 의 inline bash 에서 스크립트로 옮긴다. 입력은 payload 의 `stack` 과 파일 목록 둘, 출력은 `src` 다. 소스 패턴 목록은 이 스크립트에 두고 worker 가 같은 것을 읽는다. §4.1 의 표 네 줄과 "꼭대기가 dashboard 층이고 아래층에 `.ml` 이 있다"를 시험한다.
2. **worker 확인과 시험.** `scripts/review/test_approval_auto_merge.py` 에 §4.2 의 갈래를 더한다. `workflow_dispatch` 실행의 `type-check` 가 PR head 의 check-run 목록에 같이 나오는지는 실제 PR 한 번으로 확인한다. 독립 PR 의 `skipped` 에 소스가 있는 경우와 없는 경우를 넣는다.
3. **1과 2를 한 스택으로 올린다.** 1만 들어가면 §4.2 가 막는 경우가 열린다.
4. **측정.** 층 10개 이상인 스택의 다음 restack 에서 `pr-type-check` 실행 수와 queued 시간을 §1 과 비교한다.

## 8. 사용자 결정

1. **부분 병합이 검사 없이 통과하는 것(§5-1)을 받아들인다.** 근거: 헌법은 native stack 을 꼭대기 PR 로 통째로 병합하게 하고, worker 도 그렇게만 한다. 얻는 것은 restack 한 번에 type-check 약 49번이다(§1). 대가: 사람이 스택 일부만 병합하면 컴파일해 보지 않은 트리가 main 에 들어가고, 병합 뒤 빌드가 그것을 알린다. 받아들이지 않으면 §6 의 "지금대로 둔다"가 남는다.
2. **부분 병합 전에 사람이 할 일을 안내서에 적을지.** 적는다면: 병합할 맨 위 층의 브랜치에서 `pr-type-check` 를 `workflow_dispatch` 로 돌리고 초록을 본 뒤 병합한다. 이 실행은 병합을 막지 못한다. 확인용이다.
