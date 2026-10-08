---
rfc: "shared-memory-appends-a-log-and-keepers-read-from-their-position"
title: "공유 기억은 바뀐 것을 한 줄씩 덧붙이고, Keeper 는 안 본 줄만 받는다"
status: Draft
created: 2026-10-08
updated: 2026-10-08
author: claude
related: ["workspace-curator-curates-changed-facts", "librarian-lifecycle"]
---

# 공유 기억은 바뀐 것을 한 줄씩 덧붙이고, Keeper 는 안 본 줄만 받는다

## 1. 문제

World Curator 는 Keeper 들의 기억에서 공유 주장과 충돌을 뽑아 원장에 모으고, 그 원장을 글 한 편(브리핑)으로 다시 써서 모든 Keeper 의 턴 프롬프트에 넣는다 (`config/prompts/keeper.md` 의 `context.workspace_memory.available`, `lib/keeper/keeper_unified_prompt.ml` 의 `format_workspace_memory_observation`).

2026-10-08 라이브에서 잰 값이다.

| 항목 | 값 |
|---|---|
| Keeper 턴 프롬프트 (26명, 중간값) | 44.6KB |
| 그중 `Shared workspace memory ledger` 구간 | 21.7KB (50%) |
| 이 구간의 판본 수 | 26명에 3가지, 19명이 같은 글 |
| 원장 | 사실 1,221개(Keeper 14명) → 주장 1,004개, 충돌 10개 |
| 사실 1개에서 나온 주장 | 897개 (89%) |
| Keeper 1명에게서 나온 주장 | 900개 (90%) |
| 주장 본문 | 중간값 647바이트, 합계 818KB |
| 브리핑 | 글 한 편 20.7KB, 출처 1,041개 |
| 브리핑 내용의 가장 최근 날짜 | 09-30. 상태는 "refresh is pending" |
| `keeper_workspace_memory_read` 호출 | 10-07 에 도구 호출 27,791번 중 2번, 10-08 에 0번 |

세 가지가 겹쳐 있다.

- **같은 글이 매 턴 다시 간다.** 21.7KB 는 Curator 가 새로 낼 때만 바뀌는데 턴마다 실린다. 공식 클라이언트로 이어 가는 턴 312번을 보면 턴마다 40~45KB 가 다시 갔고, 그 절반쯤이 이 구간이다.
- **글이 한 편이라 조금만 바뀌어도 전부 다시 만든다.** 출처 1,041개 중 4개가 사라지자 남은 1,037개로 처음부터 다시 만드는 중이다. `lib/workspace_memory/workspace_memory_briefing.mli` 가 그렇게 적는다: "Deletions or changed source contents rebuild without old summary prose." 다시 만드는 동안 Keeper 는 낡은 글을 받는다.
- **꺼내 읽는 길은 쓰이지 않는다.** 읽기 도구는 이틀 동안 2번 불렸다. 본문을 프롬프트에서 빼고 조회만 남기면 Keeper 는 사실상 아무것도 받지 못한다.

운영자는 2026-10-07 에 고칠 방향을 정했다 (#41525).

- 공유 정보를 Keeper 에게 전달하는 것은 기능의 일부다. 개수와 조회 도구만 남기지 않는다 (#41526 철회).
- 의미 있는 변화는 Keeper 에게 닿고, 바뀌지 않은 것은 다시 만들지 않는다.
- 실패가 마지막으로 유효했던 공유 맥락을 조용히 지우지 않는다.
- 임의의 숫자로 자르지 않는다.

이 RFC 는 두 번째 줄을 구조로 만든다.

## 2. 참고한 틀

Karpathy 의 "LLM Wiki" (<https://gist.github.com/karpathy/442a6bf555914893e9891c11519de94f>) 는 LLM 이 유지하는 지식 묶음을 세 층과 길잡이 파일 둘로 나눈다. 아이디어 글이고 측정은 없다. 근거가 아니라 틀로 쓴다.

| LLM Wiki | 하는 일 | 지금 MASC |
|---|---|---|
| raw sources | 고치지 않는 원문 | Keeper 기억의 사실. Curator 는 읽기만 한다 |
| wiki | LLM 이 쓰고 고치는 정리본. 원문 하나가 페이지 10~15장을 고친다 | 주장 1,004개(너무 잘다)와 브리핑 한 편(너무 크다) |
| schema | 쓰는 규칙 | `workspace_memory_curator.md`, `workspace_memory_briefing.md` |
| `index.md` | 페이지마다 한 줄. 읽는 쪽이 먼저 본다 | 없다 |
| `log.md` | 무슨 일이 언제 있었는지 덧붙이기만 하는 기록 | 없다. 폴더에 `ledger.json`, `briefing.json` 둘뿐이다 |

MASC 에 없는 것이 `log.md` 와 `index.md` 다. 이 RFC 는 `log.md` 하나를 만든다. 글은 `log.md` 의 쓸모를 이렇게 적는다: "helps the LLM understand what's been done recently."

그대로 옮기지 않는 것이 하나 있다. LLM Wiki 에서는 읽는 쪽이 `index.md` 부터 스스로 찾아 읽는다. 질문이 곧 그 턴의 일이기 때문이다. Keeper 는 자기 일이 따로 있고 읽기 도구를 부르지 않는다(1장). 그래서 log 는 밀어 준다.

전체를 다시 쓰는 방식의 위험은 Agentic Context Engineering(arXiv 2510.04618)이 "context collapse" 로 보고했다. AppWorld 에서 18,282토큰이던 글이 다음 갱신에서 122토큰이 됐고 정확도가 66.7 에서 57.1 로 떨어졌다(Figure 2, 기준선 63.7). 에이전트 하나의 요령집 실험이라 여럿이 보는 기억에 그대로 옮길 수는 없다. 그 논문의 처방이 이 RFC 와 같다: 전체를 다시 쓰지 않고 항목을 덧붙인다.

## 3. 결정

### 3.1 log 는 덧붙이기만 한다

Curator 가 원장을 바꿀 때마다 무엇이 바뀌었는지를 log 에 덧붙인다 (`<base>/.masc/workspace-memory/log.jsonl`). 이미 쓴 줄은 고치지 않고 지우지 않는다.

한 줄의 모양은 원장이 이미 아는 것에서 나온다. `Workspace_memory_ledger.reconcile` 이 사라진 사실을 주고, `apply` 가 사실마다 내린 결정(`Join_claim`, `Create_claim`, `Join_conflict`, `Create_conflict`, `Exclude`)을 받는다. log 는 그 결과를 적는다.

```ocaml
type change =
  | Claim_created of { claim_id : string; by : string; line : string }
  | Claim_joined of { claim_id : string; by : string }
  | Conflict_created of { conflict_id : string; by : string list; line : string }
  | Conflict_joined of { conflict_id : string; by : string }
  | Claim_dropped of { claim_id : string }
  | Conflict_dropped of { conflict_id : string }

type entry = { seq : int; at : string; change : change }
```

- `seq` 는 1부터 하나씩 는다. 줄의 이름이자 읽는 위치의 단위다.
- `Exclude` 는 줄을 만들지 않는다. 공유할 만한지를 가르는 판정은 지금도 Curator 가 한다. 새 판정을 더하지 않는다.
- `Claim_joined` 는 다른 Keeper 가 같은 주장에 합류했다는 뜻이다. 지금 원장에서 둘 이상의 Keeper 가 걸친 주장은 104개뿐이고, 이 줄이 그 신호를 따로 드러낸다.
- 틀린 소식은 고치지 않는다. 근거가 된 사실이 사라지면 `Claim_dropped` 가 뒤에 붙는다. 읽는 쪽은 뒤의 줄을 보고 앞의 줄이 더는 유효하지 않다는 것을 안다.
- 원장 저장과 log 덧붙이기는 한 실행 안에서 같이 한다. 두 쓰기 사이에 죽는 경우는 6장 Q6 에서 정한다.

### 3.2 한 줄은 Curator 가 쓴다

주장 본문은 중간값이 647바이트라 그대로 실으면 소식이 아니라 본문이 된다. 그렇다고 앞에서 자르지 않는다. #41525 가 막은 것이 원장이 임의의 길이로 자르는 것이었다.

Curator 가 새 주장이나 새 충돌을 만들 때 한 문장을 같이 쓴다. 답의 모양(`RFC-workspace-curator-curates-changed-facts.md` 2.5)에서 "새 주장"과 "새 충돌"에 `line` 필드가 하나 는다.

- 받는 쪽 검사는 구조만 본다: 비어 있지 않고 줄바꿈이 없다. 길이로 거절하지 않는다.
- `line` 은 그 줄을 만든 log 항목에 같이 저장한다. 나중에 주장이 사라져도 log 만으로 지난 소식을 읽을 수 있다.
- 합류와 사라짐 줄은 문장을 새로 쓰지 않는다. 같은 id 를 만든 줄의 `line` 을 가져와 프롬프트 틀이 그린다.

### 3.3 Keeper 는 자기 위치 뒤의 줄만 받는다

Keeper 마다 "여기까지 받았다"는 `seq` 하나를 둔다.

- 턴 프롬프트에는 그 위치 뒤의 줄만 싣는다. 새 줄이 없으면 한 줄("새 공유 소식 없음")만 싣는다.
- 위치는 그 줄을 실은 턴이 성공으로 끝났을 때만 옮긴다. 실패한 턴이 받은 줄은 다음 턴에 다시 간다. 이벤트 큐가 이미 이렇게 한다 (`lib/keeper/keeper_heartbeat_loop.ml` 의 `Batch_no_action`).
- 자기 사실에서만 나온 줄은 싣지 않는다. 자기가 이미 아는 것이다.
- **소식은 턴을 만들지 않는다.** 새 줄이 생겼다고 Keeper 를 깨우지 않는다. 어차피 도는 턴에 실린다. 이벤트 큐에 태우지 않는 이유가 이것이다. 이벤트는 깨우고, 응답을 요구한다.
- 줄에는 `#412` 처럼 `seq` 를 붙인다. 자세한 내용은 `keeper_workspace_memory_read` 에 `{"entry": 412}` 를 주어 읽는다. 64자 해시를 프롬프트에 싣지 않는다.

### 3.4 프롬프트에서 브리핑 본문을 뺀다

`context.workspace_memory.available` 에서 `{{briefing}}` 을 빼고 그 자리에 3.3 의 줄을 넣는다. 지난 내용은 꺼내 읽는다.

#41909(열려 있는 초안)가 본문을 빼고 조회(`query`, `id`, `view`)를 더한다. 그 PR 만 들어가면 1장의 "꺼내 읽는 길은 쓰이지 않는다"에 걸린다. 이 RFC 의 3단계(5장)가 같이 들어가야 #41525 의 "전달은 기능의 일부"를 지킨다.

### 3.5 실패했을 때

- Curator 가 돌지 못하면 새 줄이 없다. Keeper 가 받는 것은 "새 공유 소식 없음"이지 낡은 글이 아니다. 지난 줄은 그대로 남는다.
- log 를 읽지 못하면 그 사실을 한 줄로 싣는다. 빈 것으로 바꾸지 않는다.
- Curator 가 지금 자주 실패하는 것(#41927)은 이 RFC 가 고치지 않는다. 그 문제가 남아 있는 동안 소식은 드물게 온다.

## 4. 다른 방법과 비교

| 방법 | 매 턴 싣는 것 | 조금 바뀌었을 때 | 전달 |
|---|---|---|---|
| 지금 | 브리핑 전문 21.7KB | 글 전체를 다시 만든다 | 된다. 낡은 글이 갈 수 있다 |
| 조회만 (#41526, #41909 단독) | 개수와 안내 | 해당 없음 | Keeper 가 읽기 도구를 불러야 한다. 이틀에 2번 불렸다 |
| 이벤트 큐로 보낸다 | 새 이벤트 | 줄 하나 | 된다. 다만 줄마다 Keeper 를 깨우고 응답을 요구한다 |
| 이 RFC | 안 본 줄 | 줄 하나를 덧붙인다 | 된다. 깨우지 않는다 |

## 5. 나눠 올리는 순서

스택으로 올린다.

1. log 의 타입, 파일, 덧붙이기. 읽는 곳은 아직 없다.
2. Curator 답에 `line` 을 더하고, `apply` 뒤에 log 를 덧붙인다.
3. Keeper 위치와 프롬프트 전달. `{{briefing}}` 을 뺀다. #41909 와 순서를 맞춘다.
4. 읽기 도구에 `{"entry": N}` 을 더한다.
5. 라이브에서 7장의 값을 잰 뒤 브리핑 합성을 어떻게 할지 정한다 (6장 Q1).

## 6. 정할 것

- **Q1. 브리핑 글을 지울 것인가.** 3단계 뒤에는 기본 프롬프트가 브리핑을 읽지 않는다. 남기면 꺼내 읽는 용도인데, 출처가 하나 사라질 때마다 전체를 다시 만드는 비용은 그대로다. 권고: 5단계에서 전달이 확인되면 합성(`Workspace_memory_briefing`, `workspace_memory_briefing.md`, `briefing.json`)을 지운다. 정리본은 주제별 페이지로 다시 정할 때(8장) 돌아온다.
- **Q2. 처음 켤 때 있던 주장 1,004개를 소식으로 흘릴 것인가.** 권고: 흘리지 않는다. log 는 켠 뒤의 변화부터 적는다. 있던 주장은 꺼내 읽는다.
- **Q3. 자기 사실에서 나온 줄을 뺄 때의 기준.** 권고: `by` 가 자기 하나뿐인 `Claim_created` 만 뺀다. 자기 주장에 다른 Keeper 가 합류한 줄은 싣는다.
- **Q4. source_bound 사실의 같은 경로가 바뀐 경우.** 지금 모양으로는 "사라짐"과 "새 주장" 두 줄이 된다. 한 줄로 이을 수 있지만(같은 Keeper, 같은 경로) 변형이 하나 는다. 권고: 처음에는 두 줄로 둔다.
- **Q5. 위치의 저장.** Keeper 마다 파일 하나(`<base>/.masc/workspace-memory/readers/<keeper>.json`)를 권한다. Librarian 의 읽은 위치와 같은 모양이다 (`RFC-librarian-lifecycle.md`).
- **Q6. 원장 저장과 log 덧붙이기 사이에 죽는 경우.** 원장을 먼저 저장하면 줄이 빠질 수 있고, log 를 먼저 쓰면 원장에 없는 변화가 소식으로 나갈 수 있다. 권고: log 를 먼저 쓰되 그 줄들이 만들 원장의 SHA-256 을 같이 적는다. 다음 실행이 저장된 원장의 SHA-256 과 맞지 않는 꼬리를 발견하면 "이 구간은 적용되지 않았다"는 줄을 덧붙이고, 읽는 쪽은 그 구간을 건너뛴다. 있던 줄은 고치지 않는다.

## 7. 검증

모델 없이 테스트하는 것:

- 덧붙인 줄의 `seq` 가 하나씩 늘고, 있던 줄의 바이트가 바뀌지 않는다.
- `apply` 결과에서 줄이 정해진 대로 나온다: 새 주장, 합류, 새 충돌, 사라짐, 제외는 줄 없음.
- 위치 뒤의 줄만 실린다. 실패한 턴 뒤에는 같은 줄이 다시 실리고, 성공한 턴 뒤에는 실리지 않는다.
- 자기 줄이 빠진다(Q3 의 기준대로).
- log 를 못 읽으면 못 읽었다는 줄이 실린다.
- 두 쓰기 사이에 죽은 뒤, 다음 실행이 Q6 에서 정한 대로 처리한다.

라이브에서 재는 것 (#41525 의 N, N+1 턴 확인):

- `Shared workspace memory ledger` 구간의 바이트. 지금 21.7KB.
- Keeper 한 명이 하루에 받는 줄 수와, 같은 줄을 두 번 받은 횟수.
- 새 주장이 생긴 뒤 다른 Keeper 의 다음 턴에 그 줄이 실렸는가.
- `keeper_workspace_memory_read` 의 `{"entry": N}` 호출 수. 지금 읽기 도구는 이틀에 2번이다.

## 8. 다루지 않는 것

- **주제별 페이지와 `index.md`.** LLM Wiki 의 본체는 페이지 단위로 고치는 정리본이다. 지금 주장 1,004개 중 900개가 Keeper 한 명의 사실이라, 한 줄씩만 적어도 index 가 1,004줄이다. 주장을 주제로 묶는 일이 먼저다. log 가 돌고 나서 따로 정한다.
- **Keeper 별 관심사로 거르기.** #41907 의 후속 항목이다. 여기서는 Curator 의 `Exclude` 와 "자기 줄 빼기"만 거른다.
- **주간 정리.** 정리도 log 의 한 줄로 덧붙일 수 있다. 하루에 몇 줄이 쌓이는지 재고 나서 정한다.
- **Curator 묶음 크기.** #41927.
- **의미 검증.** log 는 원장과 같이 모델의 해석이다. Keeper 기억을 바꾸지 않는다.
