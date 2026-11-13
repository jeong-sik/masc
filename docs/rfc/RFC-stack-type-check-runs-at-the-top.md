---
rfc: "stack-type-check-runs-at-the-top"
title: "스택의 type-check 는 꼭대기 PR 에서 한 번 돈다"
status: Implemented
created: 2026-11-12
updated: 2026-11-14
author: claude
supersedes: []
superseded_by: null
related: []
implementation_prs: [51535, 51536, 51564]
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

- 스택에 속한 PR 은 webhook payload 의 `pull_request` 에 `stack` 이 붙는다. REST 의 `stack` 은 `number`, `position`, `size`, `base{ref, sha}` 를 가진다. webhook 쪽 필드 목록은 문서에 없다. 실행 로그로 확인했다(§7 의 0단계): `base{ref, sha}`, `id`, `number`, `position`, `size`.
- PR 이 스택에 들어가면 `pull_request` 이벤트의 `stacked` action 이 온다고 적혀 있다. 스택에서 빠질 때의 action 은 찾지 못했다. 둘 다 실행으로 확인하지 못했다.
- 병합 조건: "All pull requests below it are approved and have passing checks."
- 부분 병합이 된다: "You can merge any number of pull requests at once, as long as they form a contiguous group starting from the lowest unmerged pull request."

병합 worker(`scripts/review/approval-auto-merge.py`)는 이 RFC 전에는 검사 결과를 읽지 않았다. 승인과 스택 모양만 확인하고, 검사는 GitHub 의 규칙에 맡겼다. worker 는 스택 전체를 꼭대기 PR 로 병합한다. 독립 PR 은 worker 가 직접 병합하지 않는다. Ready 가 되면 worker 가 GitHub 의 자동 병합 예약을 걸고, GitHub 이 승인과 필수 검사가 채워질 때 병합한다.

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
- 비교는 두 트리를 맞대는 `git diff A B` 다. merge base 를 찾지 않는다. 스택 PR 의 merge commit 은 아래층의 merge commit 위에 만들어지고, 맨 아래 층의 merge commit 은 `stack.base.sha` 위에 만들어진다. 그래서 이 비교는 스택이 바꾼 파일만 준다(§7 의 0단계). `stack.base.sha` 는 스택을 만들거나 rebase 한 때의 main 끝이다. 브랜치가 갈라진 지점이 아니다. 둘이 어긋나는 경우가 있더라도 목록은 늘어나는 쪽으로만 틀린다.
- 모르는 모양은 검사를 더 하는 쪽으로 떨어진다. 검사를 덜 하는 쪽으로 떨어지는 갈래는 "아래층" 하나다.
- 판정은 `scripts/ci/pr_source_changes.py` 가 한다. `changes` job 은 merge commit 에서 그 파일 하나를 받아 돌린다. 시험(`scripts/ci/test_pr_source_changes.py`)은 type-check job 의 첫 step 이 돌린다. 스크립트와 시험도 소스 패턴에 들어 있어서 둘 중 하나가 바뀌면 그 job 이 돈다.
- `on.pull_request` 에 `stacked` 는 더하지 않았다(§6).

### 4.2 병합 worker

아래층의 `skipped` 는 "꼭대기가 검사했다"는 뜻이다. 이 뜻은 그 PR 이 그 스택의 아래층으로 남아 있는 동안만 맞다.
PR 이 스택에서 빠지거나 꼭대기가 사라지면 `skipped` 는 그대로 남고 뜻만 틀려진다. `skipped` 를 믿어도 되는지는 worker 가 병합 직전에 확인한다.

worker 는 병합하려는 head 의 `type-check` check-run 가운데 가장 새 것을 읽는다. 스택이면 꼭대기 PR 의 head 이고, 독립 PR 이면 그 PR 의 head 다. 읽는 자리는 둘이다.

- **직접 병합과 스택 병합 전**(`prepare_reads`): 승인과 스택 모양을 다 확인한 뒤다.
- **독립 PR 의 자동 병합 예약 전**(`reservation_reads`): 예약이 걸리면 GitHub 이 필수 검사만 보고 병합한다. 스택에서 빠진 PR 이 지나는 자리가 여기다. 확인이 안 되면 예약을 걸지 않고, 걸려 있던 예약은 푼다.

가장 새 실행에 따라:

- 완료된 `skipped` 면 병합 범위가 main 대비 바꾼 파일을 직접 읽는다(`compare/main...{head}`). 소스가 없으면 진행한다. 있으면 `Hold` 다. 파일이 300개(compare 상한)에 닿으면 `Hold` 다. 옮긴 파일은 옛 이름도 본다.
- `success` 면 진행한다.
- 그 밖은 모두 `Hold` 다(#51578). 진행 중, 없음, 실패나 취소 같은 다른 결론, 읽을 수 없는 응답이 여기에 든다.
  - 진행 중인 실행은 `skipped` 로 끝날 수 있다. 예약이 걸려 있으면 GitHub 은 그 `skipped` 로 병합한다. 그래서 worker 는 끝난 결과를 직접 본 뒤에만 예약하거나 병합을 요청한다.
  - status 와 conclusion 은 GitHub 문서에 적힌 값만 받는다. 그 밖의 값, 모양이 어긋난 check-run 은 읽을 수 없는 응답이다. 판정은 `scripts/review/type-check-state.py` 가 닫힌 타입으로 한다.
  - `Hold` 된 범위는 30분마다 도는 `approval-merge-sweep` 이 worker 를 다시 돌린다. 승인이 type-check 보다 먼저 끝난 PR 은 병합이 길게는 30분 늦는다. 검사가 끝날 때 worker 를 깨우는 이벤트는 여전히 없다.

예약 전 읽기가 끝까지 가지 못하면 이미 걸린 예약을 푼다. `Hold`, HTTP 오류, 읽을 수 없는 응답, 한도가 모두 같다. GET 하나가 120초 안에 끝나지 않으면 실패한 읽기다.

스택은 한 가지를 더 본다. 꼭대기의 type-check 는 꼭대기 head 의 트리를 컴파일했다. 병합되지 않은 아래층의 지금 head 가 모두 꼭대기 head 에 들어 있어야 그 결과가 아래층에도 맞다. worker 는 `compare/{맨 아래 층 head}...{꼭대기 head}` 의 commit 목록에서 아래층 head 를 찾는다. 빠진 층이 있으면 `Hold` 다.

소스 패턴은 `changes` job 과 같은 목록을 쓴다. 목록은 한 곳에 두고 둘이 같이 읽는다(§7 의 1단계).

이 확인이 막는 경우:

- 아래층 PR 이 스택에서 빠져 독립 PR 이 됐다(base 를 main 으로 바꿨거나 스택이 풀렸다). head 가 그대로면 `pr-type-check` 를 깨우는 이벤트가 없다. 그 PR 의 `skipped` 는 옛 꼭대기에 맡긴 결과로 남는다. worker 는 독립 PR 로 보고 그 PR 의 diff 를 직접 읽는다.
- 꼭대기 PR 이 스택에서 빠져서 아래층이 새 꼭대기가 됐다. 그 층의 `skipped` 도 옛 꼭대기에 맡긴 결과다.

닫힌 채 병합되지 않은 PR 이 스택에 남아 있는 경우는 이 RFC 전부터 `stack-scope.py` 가 막는다.

이 확인은 PR 이 스택을 떠날 때 오는 이벤트 이름을 몰라도 성립한다. worker 는 이벤트가 아니라 병합 시점의 상태를 읽는다.

`Hold` 메시지는 다음 한 단계를 적는다: 그 PR 의 브랜치에서 `pr-type-check` 를 `workflow_dispatch` 로 돌린다.
이 실행은 소스 판정 없이 type-check 를 돌리고, 결과를 같은 head commit 에 남긴다(그 commit 의 check-run 목록에 나오는 것을 확인했다. ruleset 의 필수 검사를 채우는지는 확인하지 못했다). 실패한 실행을 "다시 실행"하면 옛 payload 를 다시 써서 아래층 판정이 되풀이된다.
같은 head 에 `type-check` 가 여럿이면 worker 는 가장 새 것(check-run id 가 가장 큰 것)을 읽는다. GitHub Actions 가 그 commit 에 남긴 것만 센다.

### 4.3 바뀌지 않는 것

- main ruleset 의 필수 검사 이름(`changes`, `type-check`).
- 스택이 아닌 PR 의 판정.
- `changes` 가 빨갛게 실패하면 병합을 막는 것(fail-closed).

## 5. 대가

1. **부분 병합은 검사 없이 통과한다.** GitHub 은 아래에서부터 이어진 층을 따로 병합하게 해 준다. 그 층들의 type-check 는 `skipped` 라서 규칙을 통과한다. 병합되는 트리(중간 층)는 아무도 컴파일해 보지 않았다. worker 는 부분 병합을 하지 않는다. 사람이 UI 나 API 로 하면 생긴다. 병합 뒤 `main-minimal-build` 가 잡는다. 2026-11-03 에 PR 단계 type-check 없이 병합된 PR 셋이 main 의 type-check 를 깨뜨렸고, `pr-type-check` 는 그래서 생겼다(workflow 머리 주석).
   - 2026-11-13T05:38Z 에 실제로 있었다. 스택 #51624 의 아래 41층이 한 번에 병합됐다. 병합 계정은 `jeong-sik` 이다. worker 는 `github.token` 으로 병합하므로 worker 의 병합이 아니다.
   - 41층의 마지막 head 는 모두 type-check 가 `skipped` 였다. 병합 뒤 `main-minimal-build`(run 43373486170)가 05:52:47Z 에 성공했다.
2. **중간 층이 단독으로 컴파일되는지 모른다.** 스택을 통째로 병합하면 main 에는 층마다 commit 이 하나씩 생긴다. 중간 commit 에서 `git bisect` 가 빌드 실패를 만날 수 있다.
3. **실패한 층을 가리키지 못한다.** 꼭대기에서 실패하면 어느 층이 원인인지는 컴파일 오류의 파일로 찾아야 한다.
4. **worker 의 API 호출이 는다.** 독립 Ready PR 은 worker 가 깨어날 때마다 check-run 읽기가 한 번 든다. type-check 가 `skipped` 면 compare 가 한 번 더 든다. 문서나 dashboard 만 바꾼 PR 이 여기에 든다. 스택은 승인이 다 모인 실행에서만 든다. 이때 층 비교가 스택의 commit 100개마다 한 번 더 든다. 층 수만큼 들지는 않는다. 이 RFC 전에는 0번이었다. 이 호출은 Actions 토큰의 시간당 한도(1,000)를 쓴다.
5. **꼭대기가 `skipped` 인 큰 스택은 멈춘다.** compare 는 파일을 300개까지만 준다. 꼭대기가 소스를 바꾸지 않았고 스택 전체가 300개 넘게 바꿨으면 worker 는 소스가 없다고 확인하지 못해 `Hold` 다. 이때는 꼭대기 브랜치에서 `pr-type-check` 를 `workflow_dispatch` 로 한 번 돌려야 한다(§4.2 의 `Hold` 메시지).
6. **사람이 직접 병합하는 길은 이 확인을 지나지 않는다.** ruleset 은 `skipped` 를 통과로 친다. 스택에서 빠진 PR 을 사람이 UI 로 병합하면 1번과 같은 일이 생긴다.
7. **옛 판정으로 검사한 스택은 한 번 멈춘다.** 꼭대기가 `skipped` 이고 아래층에 소스가 있는 스택은 worker 가 `Hold` 한다. 스택이 다시 rebase 되면 새 판정으로 꼭대기에서 type-check 가 돈다. 아니면 꼭대기 브랜치에서 `pr-type-check` 를 `workflow_dispatch` 로 돌린다.
8. **아래층만 push 하고 위층을 다시 올리지 않으면 스택이 멈춘다.** 아래층은 `skipped` 이고, 꼭대기의 `success` 는 그 commit 을 담지 않은 트리의 결과다. worker 는 꼭대기 head 가 그 층의 head 를 담지 않는 것을 보고 `Hold` 한다(§4.2). 위층을 다시 올리면 풀린다. `gh stack` 으로 올리면 모든 층이 같이 올라가서 생기지 않는다. 사람이 직접 병합하면 6번과 같다.
9. **승인이 type-check 보다 먼저 끝나면 병합이 늦는다.** worker 는 끝나지 않은 검사에서 예약도 병합 요청도 하지 않는다. 다음 이벤트나 30분 확인 job 이 다시 본다.
10. **`success` 를 읽고 예약한 뒤 같은 head 에 새 실행이 생기는 경우는 다음 worker 실행까지 보지 못한다.** 그 실행이 `skipped` 로 끝나도 예약은 남아 있다. 다음 worker 실행이 예약을 푼다.

## 6. 고르지 않은 것

- **지금대로 둔다.** 대가가 없다. restack 한 번에 type-check 약 50번이 그대로다.
- **가장 위의 OCaml 층에서만 돈다.** 꼭대기가 dashboard 층이어도 도는 층이 하나로 정해진다. 층마다 "내 위에 OCaml 변경이 있는가"를 알아야 하는데, payload 에는 위층 정보가 없다. REST 를 층마다 불러야 한다.
- **diff 가 그대로인 rebase 는 건너뛴다.** 이전 head 의 결과를 찾아야 해서 REST 가 든다. base 가 움직였으므로 이전 결과가 지금 트리를 증명하지도 않는다.
- **`pr-type-check` 를 base 가 바뀔 때 다시 돌린다.** base 변경은 `edited` action 으로 온다. `edited` 는 제목·본문 수정에도 오고, trigger 단계에서 base 변경만 고를 수 없다. 제목을 고칠 때마다 실행이 하나 생기고, 같은 PR 의 진행 중인 type-check 를 취소한다(concurrency 그룹이 PR 단위다). 스택이 풀릴 때 오는 action 은 이름도 모른다. §4.2 는 이벤트 없이 같은 구멍을 막는다.
- **`on.pull_request` 에 `stacked` 를 더한다.** 독립 PR 이 스택의 아래층이 될 때 다시 판정하려는 것이었다. Actions 가 그 이름을 trigger type 으로 받는지 확인하지 못했다. 틀린 이름이면 필수 검사가 안 생겨 모든 PR 이 막힌다. 넣지 않아도 검사는 줄지 않는다. 아래층이 된 PR 에 이전의 독립 판정이 남을 뿐이다.
- **부분 병합을 규칙으로 막는다.** GitHub 에 "스택은 통째로만"이라는 규칙이 없다. 아래층에 늘 빨간 필수 검사를 두면 통째 병합도 막힌다.

## 7. 하네스와 구현 순서

0. **payload 확인(#51535, 끝).** `changes` 가 이벤트의 `action`, `base.sha`, `stack` 을 로그에 찍는다. run 43163847809(스택 #51537 의 꼭대기, `synchronize`)에서 본 것:
   - `stack` 은 `{base:{ref, sha}, id, number, position, size}` 다. REST `pulls/N` 의 `stack` 과 같은 값이다.
   - `position` 과 `size` 는 병합된 층도 센다. 스택 #51256 은 `size 86` 이었고 병합된 층이 둘이었다. 열린 층 가운데 맨 아래가 `position 3` 이었다.
   - `stack.base.sha` 는 스택을 만든 때의 main 끝이었다. 브랜치가 갈라진 지점보다 commit 여럿 뒤였다. 꼭대기의 merge commit 과 비교한 파일은 스택이 바꾼 5개였고, main 이 그 사이 바꾼 42개는 섞이지 않았다.
   - 확인하지 못한 것: PR 이 스택에 들어가거나 빠질 때 오는 이벤트, main 이 움직인 뒤 GitHub 이 merge commit 과 `stack.base.sha` 를 같이 바꾸는지.
1. **판정 스크립트와 시험(#51536, 끝).** `scripts/ci/pr_source_changes.py` 와 시험 13개. 로컬 git 저장소로 2층 스택을 만들어 스크립트를 실제로 돌린다. "꼭대기가 dashboard 층이고 아래층에 `.ml` 이 있다"가 들어 있다.
2. **worker 확인과 시험(#51564, 끝).** `scripts/review/test_approval_auto_merge.py` 에 시험 9개. `workflow_dispatch` 실행의 `type-check` 가 그 commit 의 check-run 목록에 나오는 것은 실제 commit(`16a8484415eb`)에서 확인했다.
3. **1과 2를 한 스택으로 올렸다.** 스택 #51537 이 2026-11-12T07:05Z 에 통째로 병합됐다.
4. **측정(2026-11-13, 끝).** 스택 #51624(TUI, 열린 층 47개)를 01:2xZ 에 통째로 다시 올렸다.
   - `pr-type-check` 실행은 68개였다. type-check job 이 runner 에서 돈 것은 꼭대기 하나(376초)다. 61개는 `skipped` 였다. 6개는 같은 PR 의 새 실행에 밀려 runner 를 잡기 전에 취소됐다.
   - 아래층의 `changes` 는 `src=false: stack #51624: the top pull request checks every layer` 로 끝났다(run 43344588397). 꼭대기는 `src=true: top of stack #51624; 155 files since 71626e7e1d80` 였다(run 43344577369).
   - `changes` job 65개가 runner 를 잡았다. 하나에 2~8초, 합쳐 261초다. runner 를 기다린 시간은 길어야 5초였다.
   - 옛 판정이면 소스를 바꾼 층마다 type-check 가 돈다. 이 스택은 49층 가운데 48층이 소스를 바꾼다(`is_source` 로 셈). 47층을 한 번 다시 올리면 type-check 가 약 46번 돈다. §1 의 job 시간(368~533초)으로 약 17,000~24,500초다. 이번에는 376초였다.
   - 실행 목록은 `actions/workflows/pr-type-check.yml/runs?created=<구간>` 으로, job 시간은 `actions/runs/<id>/jobs` 로 읽었다.

## 8. 사용자 결정

1. **부분 병합이 검사 없이 통과하는 것(§5-1)을 받아들인다. — 받아들임(2026-11-12).** 근거: 헌법은 native stack 을 꼭대기 PR 로 통째로 병합하게 하고, worker 도 그렇게만 한다. 얻는 것은 restack 한 번에 type-check 약 49번이다(§1). 대가: 사람이 스택 일부만 병합하면 컴파일해 보지 않은 트리가 main 에 들어가고, 병합 뒤 빌드가 그것을 알린다. 받아들이지 않으면 §6 의 "지금대로 둔다"가 남는다.
2. **부분 병합 전에 사람이 할 일을 안내서에 적을지. — 답 없음.** 적는다면: 병합할 맨 위 층의 브랜치에서 `pr-type-check` 를 `workflow_dispatch` 로 돌리고 초록을 본 뒤 병합한다. 이 실행은 병합을 막지 못한다. 확인용이다.
